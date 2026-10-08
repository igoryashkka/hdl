// Module : phy_llr_demap   soft demapper for 16-QAM with per-bin side information (MMSE bias threshold + reliability gain).
//   Per data bin (valid-only stream, in_first restarts the bin counter): parameters {T (16 bit), gm (6 bit, 32..63), ge (7 bit signed)}
//   are read from the packet's parameter RAM (rd_addr -> rd_data, 1 cycle) :
//        axis value x:   L0 = -x ,  L1 = |x| - T
//        LLR = sat( (L * gm) >> (SH_C - ge) )   (round half up; left shift when SH_C - ge <= 0), 6 bit symmetric (+-31)
//   Output bit order: [I b0, I b1, Q b0, Q b1], LLR > 0 => bit 0 (same convention as phy_qam_demapper).
// Latency 5, throughput 1 bin/cycle, 4 DSP.   Golden: python/phy2_fixed_ref.py::demap_soft (bit-exact)
module phy_llr_demap
  import phy_pkg::*;
  import phy_soft_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic [10:0]            rd_addr,
  input  logic [28:0]            rd_data,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [5:0]      out_llr [4]
);
  logic [10:0] cnt;
  assign rd_addr = in_first ? 11'd0 : cnt;
  always_ff @(posedge clk) begin
    if (rst) cnt <= '0; else if (in_valid) cnt <= rd_addr + 1'b1;
  end

  // S1: data registers (parameters arrive in this cycle)
  logic v1, f1, l1; logic signed [IQ_W-1:0] x1r, x1i;
  always_ff @(posedge clk) begin
    if (rst) v1 <= 1'b0; else v1 <= in_valid;
    f1 <= in_first; l1 <= in_last; x1r <= in_re; x1i <= in_im;
  end
  wire [15:0]       t1  = rd_data[28:13];
  wire [5:0]        gm1 = rd_data[12:7];
  wire signed [6:0] ge1 = rd_data[6:0];

  // S2: axis values (17 bit signed)
  logic v2, f2, l2; logic signed [16:0] a2 [4]; logic [5:0] gm2; logic signed [6:0] ge2;
  always_ff @(posedge clk) begin
    if (rst) v2 <= 1'b0; else v2 <= v1;
    f2 <= f1; l2 <= l1; gm2 <= gm1; ge2 <= ge1;
    a2[0] <= -17'(x1r);
    a2[1] <= (x1r[IQ_W-1] ? 17'(-x1r) : 17'(x1r)) - 17'($signed({1'b0, t1}));
    a2[2] <= -17'(x1i);
    a2[3] <= (x1i[IQ_W-1] ? 17'(-x1i) : 17'(x1i)) - 17'($signed({1'b0, t1}));
  end

  // S3: products
  logic v3, f3, l3; logic signed [23:0] p3 [4]; logic signed [7:0] sh3;
  always_ff @(posedge clk) begin
    if (rst) v3 <= 1'b0; else v3 <= v2;
    f3 <= f2; l3 <= l2;
    for (int i = 0; i < 4; i++) p3[i] <= 24'(a2[i]) * 24'($signed({1'b0, gm2}));
    sh3 <= 8'(SH_C) - 8'(ge2);
  end

  // S4: rounding add
  logic v4, f4, l4; logic signed [39:0] p4 [4]; logic signed [7:0] sh4;
  always_ff @(posedge clk) begin
    if (rst) v4 <= 1'b0; else v4 <= v3;
    f4 <= f3; l4 <= l3; sh4 <= sh3;
    for (int i = 0; i < 4; i++)
      p4[i] <= (sh3 > 8'sd0) ? (40'(p3[i]) + (40'sd1 <<< (sh3 - 8'sd1))) : 40'(p3[i]);
  end

  // S5: shift and saturate
  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= v4;
    out_first <= f4; out_last <= l4;
    for (int i = 0; i < 4; i++) begin
      logic signed [39:0] v;
      v = (sh4 > 8'sd0) ? (p4[i] >>> sh4) : (p4[i] <<< (-sh4));
      if (v > 40'sd31) out_llr[i] <= 6'sd31; else if (v < -40'sd31) out_llr[i] <= -6'sd31; else out_llr[i] <= v[5:0];
    end
  end
endmodule
