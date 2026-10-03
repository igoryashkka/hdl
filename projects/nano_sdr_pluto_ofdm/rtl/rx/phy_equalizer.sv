// Module : phy_equalizer   one-tap zero-forcing equalizer X = Y * w, w = (mr + j*mi) * 2^-E from phy_channel_estimator.
//   The weight RAM is read through (rd_addr -> rd_data, 1 cycle, address = active-bin index, restarted at in_first).
//   X = round_half_up((Y*w_m) >> E) (left shift if E < 0), saturated to 16 bit; the QAM unit of the result equals the TX
//   constellation unit (QAM_UNIT = 4096), independent of the RX gain.
// Valid-only, latency = 7 cycles (products, sums, round-add, 2-step barrel shift, saturate), throughput 1 bin/cycle, 4 DSP.   Golden: python/rx_fixed_ref.py::equalize (bit-exact)
module phy_equalizer
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic [10:0]            rd_addr,
  input  logic [39:0]            rd_data,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 7;
  logic [10:0] scnt;
  assign rd_addr = in_first ? 11'd0 : scnt;
  always_ff @(posedge clk) begin
    if (rst) scnt <= '0; else if (in_valid) scnt <= rd_addr + 1'b1;
  end

  // S1: data registers (weights arrive from the RAM in the same cycle)
  logic v1, f1, l1; logic signed [IQ_W-1:0] y1r, y1i;
  always_ff @(posedge clk) begin
    if (rst) v1 <= 1'b0; else v1 <= in_valid;
    f1 <= in_first; l1 <= in_last; y1r <= in_re; y1i <= in_im;
  end
  wire signed [15:0] mr = rd_data[39:24];
  wire signed [15:0] mi = rd_data[23:8];
  wire signed [7:0]  ex = rd_data[7:0];

  // S2: products
  logic v2, f2, l2; logic signed [31:0] p_rr, p_ii, p_ri, p_ir; logic signed [7:0] e2;
  always_ff @(posedge clk) begin
    if (rst) v2 <= 1'b0; else v2 <= v1;
    f2 <= f1; l2 <= l1; e2 <= ex;
    p_rr <= y1r * mr; p_ii <= y1i * mi; p_ri <= y1r * mi; p_ir <= y1i * mr;
  end

  // S3: sums
  logic v3, f3, l3; logic signed [32:0] s_r, s_i; logic signed [7:0] e3;
  always_ff @(posedge clk) begin
    if (rst) v3 <= 1'b0; else v3 <= v2;
    f3 <= f2; l3 <= l2; e3 <= e2;
    s_r <= 33'(p_rr) - 33'(p_ii);
    s_i <= 33'(p_ri) + 33'(p_ir);
  end

  // S4: direction/amount and rounding add (E range in practice -15..34 -> 50-bit datapath is sufficient)
  logic v4, f4, l4; logic signed [49:0] t4r, t4i; logic [5:0] amt4; logic left4;
  wire  signed [49:0] rnd_c = (e3 > 0) ? (50'sd1 <<< (e3 - 1)) : 50'sd0;
  always_ff @(posedge clk) begin
    if (rst) v4 <= 1'b0; else v4 <= v3;
    f4 <= f3; l4 <= l3;
    left4 <= (e3 <= 0);
    amt4  <= (e3 > 0) ? 6'(e3) : 6'(-e3);
    t4r <= 50'(s_r) + rnd_c;
    t4i <= 50'(s_i) + rnd_c;
  end

  // S5: coarse shift (multiples of 8) ; S6: fine shift (0..7)
  logic v5, f5, l5; logic signed [49:0] t5r, t5i; logic [2:0] fine5; logic left5;
  always_ff @(posedge clk) begin
    if (rst) v5 <= 1'b0; else v5 <= v4;
    f5 <= f4; l5 <= l4; left5 <= left4; fine5 <= amt4[2:0];
    t5r <= left4 ? (t4r <<< {amt4[5:3], 3'b000}) : (t4r >>> {amt4[5:3], 3'b000});
    t5i <= left4 ? (t4i <<< {amt4[5:3], 3'b000}) : (t4i >>> {amt4[5:3], 3'b000});
  end
  logic v6, f6, l6; logic signed [49:0] t6r, t6i;
  always_ff @(posedge clk) begin
    if (rst) v6 <= 1'b0; else v6 <= v5;
    f6 <= f5; l6 <= l5;
    t6r <= left5 ? (t5r <<< fine5) : (t5r >>> fine5);
    t6i <= left5 ? (t5i <<< fine5) : (t5i >>> fine5);
  end

  // S7: saturate to 16 bit
  function automatic logic signed [IQ_W-1:0] sat16(input logic signed [49:0] t);
    if (t > 50'sd32767)       return 16'sd32767;
    else if (t < -50'sd32768) return -16'sd32768;
    else                      return t[15:0];
  endfunction
  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= v6;
    out_first <= f6; out_last <= l6;
    out_re <= sat16(t6r);
    out_im <= sat16(t6i);
  end
endmodule
