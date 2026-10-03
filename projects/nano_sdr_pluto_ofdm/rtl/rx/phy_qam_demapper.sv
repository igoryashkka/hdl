// Module : phy_qam_demapper  max-log soft demapper (4/16/64), LLR>0 => bit 0.
// Per axis: llr0 = -x ; t_k = |t_{k-1}| - UNIT*2^(m-k) (t_0 = x) ; llr_k = t_k  (k>=1)
// then llr = sat((t*GAIN) >>> SHIFT) to LLR_W bits. Output bit order == mapper input bit order.
// Latency = 2 (stage 1: t values, stage 2: scale+saturate). Throughput 1 symbol/cycle.
// Widths : in IQ_W signed; t in TW = IQ_W+2 (no overflow); product in TW+8 (GAIN < 256).
// Golden : python/qam_ref.py (bit-exact)
module phy_qam_demapper
  import phy_pkg::*;
#(
  parameter int ORDER = QAM_ORDER,
  parameter int UNIT  = QAM_UNIT,
  parameter int GAIN  = LLR_GAIN,
  parameter int SHIFT = LLR_SHIFT
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    in_valid,
  input  logic                    in_last,
  input  logic signed [IQ_W-1:0]  in_i,
  input  logic signed [IQ_W-1:0]  in_q,
  output logic                    out_valid,
  output logic                    out_last,
  output logic signed [LLR_W-1:0] out_llr [$clog2(ORDER)]
);
  localparam int LATENCY = 2;
  localparam int BPS = $clog2(ORDER);
  localparam int M   = BPS / 2;
  localparam int TW  = IQ_W + 2;
  localparam int PW  = TW + 8;

  logic signed [TW-1:0] t_q [BPS];
  logic signed [TW-1:0] t_c [BPS];
  logic                 v1, l1;

  always_comb begin
    logic signed [TW-1:0] x, t;
    for (int b = 0; b < BPS; b++) t_c[b] = '0;
    for (int ax = 0; ax < 2; ax++) begin
      x = (ax == 0) ? TW'(in_i) : TW'(in_q);
      t_c[ax*M] = -x;
      t = x;
      for (int k = 1; k < M; k++) begin
        t = (t[TW-1] ? -t : t) - TW'(UNIT * (1 << (M - k)));
        t_c[ax*M + k] = t;
      end
    end
  end

  function automatic logic signed [LLR_W-1:0] scale_sat(input logic signed [TW-1:0] t);
    logic signed [PW-1:0] p, s, hi, lo;
    hi = PW'((1 << (LLR_W - 1)) - 1);
    lo = -PW'(1 << (LLR_W - 1));
    p  = PW'(t) * PW'(GAIN);
    s  = p >>> SHIFT;
    if (s > hi)      return LLR_W'(hi);
    else if (s < lo) return LLR_W'(lo);
    else             return LLR_W'(s);
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      v1 <= 1'b0; l1 <= 1'b0; out_valid <= 1'b0; out_last <= 1'b0;
    end else begin
      v1 <= in_valid;  l1 <= in_valid & in_last;
      out_valid <= v1; out_last <= l1;
    end
    if (in_valid) for (int b = 0; b < BPS; b++) t_q[b] <= t_c[b];
    if (v1)       for (int b = 0; b < BPS; b++) out_llr[b] <= scale_sat(t_q[b]);
  end
endmodule
