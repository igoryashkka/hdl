// Module : phy_g_smooth   frequency smoothing of the LS channel estimate G = Y * sigma (moving average over the 2*S+1 = 3 neighbouring bins).
//   The LTS channel estimate of one bin carries the noise of that bin only; the channel itself is smooth over a few subcarriers (delay
//   spread << 1 / (9 * 15 kHz)), so averaging 3 neighbours cuts the estimation noise by 4.8 dB. This removes most of the ~3 dB SNR loss that
//   a single-symbol LS estimate costs at low SNR (MAX RANGE, QPSK 1/2).
//   Stream in : G of the 1200 active bins (valid-only, in_first = bin 0, in_last = bin 1199), 16 bit signed.
//   Stream out: the same 1200 bins, smoothed: y[k] = (sum_{j = max(0, k-4)}^{min(1199, k+4)} x[j] * rc(count) + 32768) >> 16,  count = number of bins in
//               the (edge-clipped) window, rc = round(65536 / count)  (golden python/phy2_fixed_ref.py::smooth_g, bit-exact).
//   Latency: 4 + 3 cycles after the input of bin k + 4; the last 4 outputs come from 4 internal flush steps after in_last (zeros are shifted in).
//   Resources: 2 x 17 bit adder trees, 2 DSP (sum * reciprocal), 9 x 32 bit window registers.
module phy_g_smooth
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic [10:0]            out_addr,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int S  = 1;            // half window: 3 bins (S = 4, 9 bins, loses on channels with delay spread > ~2 us; S = 1 keeps ~2 dB at every channel tested)
  localparam int W  = 2 * S + 1;
  localparam int NA = NUM_ACTIVE_SC;

  // ---------------------------------------------------------------- step generator: one step per input bin, then S flush steps
  logic [10:0] t;               // step index (0 .. NA + S - 1)
  logic        flushing;
  logic [2:0]  fcnt;
  logic        step, step_first, step_zero;
  assign step       = in_valid | flushing;
  assign step_first = in_valid & in_first;
  assign step_zero  = flushing;                                   // flush: shift a zero in

  logic signed [IQ_W-1:0] wr_ [W], wi_ [W];                       // window, index 0 = newest
  wire [10:0] t_cur = step_first ? 11'd0 : t;
  always_ff @(posedge clk) begin
    if (rst) begin t <= '0; flushing <= 1'b0; fcnt <= '0; end
    else begin
      if (step) t <= t_cur + 1'b1;
      if (in_valid && in_last) begin flushing <= 1'b1; fcnt <= 3'(S - 1); end
      else if (flushing) begin if (fcnt == 3'd0) flushing <= 1'b0; else fcnt <= fcnt - 1'b1; end
    end
    if (step) begin
      wr_[0] <= step_zero ? '0 : in_re;
      wi_[0] <= step_zero ? '0 : in_im;
      for (int i = 1; i < W; i++) begin
        wr_[i] <= step_first ? '0 : wr_[i-1];
        wi_[i] <= step_first ? '0 : wi_[i-1];
      end
    end
  end

  // S1: step registered (window now holds x[t-8 .. t]); output bin k = t - S exists for t >= S
  logic        v1, f1, l1; logic [10:0] k1; logic [3:0] c1;
  always_ff @(posedge clk) begin
    if (rst) v1 <= 1'b0;
    else v1 <= step && (t_cur >= 11'(S));
    k1 <= t_cur - 11'(S);
    f1 <= (t_cur == 11'(S)); l1 <= (t_cur == 11'(NA + S - 1));
  end
  // the window registers are updated at the same edge as v1/k1: use them one cycle later
  logic        v2, f2, l2; logic [10:0] k2; logic [3:0] c2;
  logic signed [IQ_W+3:0] s2r, s2i;                                 // sum of 9 values
  function automatic logic [3:0] cnt_of(input logic [10:0] k);
    int lo, hi;
    lo = (int'(k) < S) ? 0 : int'(k) - S;
    hi = (int'(k) + S > NA - 1) ? NA - 1 : int'(k) + S;
    return 4'(hi - lo + 1);
  endfunction
  always_ff @(posedge clk) begin
    if (rst) v2 <= 1'b0; else v2 <= v1;
    f2 <= f1; l2 <= l1; k2 <= k1; c2 <= cnt_of(k1);
    begin
      logic signed [IQ_W+3:0] ar, ai;
      ar = '0; ai = '0;
      for (int i = 0; i < W; i++) begin ar = ar + (IQ_W+4)'(wr_[i]); ai = ai + (IQ_W+4)'(wi_[i]); end
      s2r <= ar; s2i <= ai;
    end
  end

  // S3: multiply by the reciprocal of the count
  function automatic logic [15:0] rc_of(input logic [3:0] c);
    case (c)
      4'd1: return 16'd0;           // never used with S = 4 (count >= 5): 65536 does not fit, kept for completeness
      4'd2: return 16'd32768;
      4'd3: return 16'd21845;
      4'd4: return 16'd16384;
      4'd5: return 16'd13107;
      4'd6: return 16'd10923;
      4'd7: return 16'd9362;
      4'd8: return 16'd8192;
      default: return 16'd7282;     // 9
    endcase
  endfunction
  logic        v3, f3, l3; logic [10:0] k3;
  logic signed [IQ_W+4+16:0] p3r, p3i;
  always_ff @(posedge clk) begin
    if (rst) v3 <= 1'b0; else v3 <= v2;
    f3 <= f2; l3 <= l2; k3 <= k2;
    p3r <= (IQ_W+21)'(s2r) * (IQ_W+21)'($signed({1'b0, rc_of(c2)})) + (IQ_W+21)'(32768);
    p3i <= (IQ_W+21)'(s2i) * (IQ_W+21)'($signed({1'b0, rc_of(c2)})) + (IQ_W+21)'(32768);
  end
  // S4: shift and register the output
  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= v3;
    out_first <= f3; out_last <= l3; out_addr <= k3;
    out_re <= p3r[IQ_W+15 : 16];
    out_im <= p3i[IQ_W+15 : 16];
  end
endmodule
