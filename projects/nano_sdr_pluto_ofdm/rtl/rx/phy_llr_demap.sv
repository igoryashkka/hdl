// Module : phy_llr_demap   soft demapper for 16-QAM and QPSK with per-bin side information (MMSE bias threshold + reliability gain).
//   Per data bin (valid-only stream, in_first restarts the bin counter): parameters {T (16 bit), gm (6 bit, 32..63), ge (7 bit signed)}
//   are read from the packet's parameter RAM (rd_addr -> rd_data, 1 cycle) :
//        axis value x:   L0 = -x ,  L1 = |x| - T
//        LLR = sat( (L * gm) >> (SH_C - ge) )   (round half up; left shift when SH_C - ge <= 0), 6 bit symmetric (+-31)
//   Output bit order: [I b0, I b1, Q b0, Q b1], LLR > 0 => bit 0 (same convention as phy_qam_demapper).
//   QPSK (qpsk = 1, sampled with every bin and pipelined with it): constellation +-9216 per axis (= 2.25 QAM_UNIT, the same mean power as
//   16-QAM), LLR = sat( ((-(x + (x >>> 3))) * gm) >> (SH_C - ge - 1) )  (x * 2.25 = x * 9/8 * 2); out_llr = [I, Q, 0, 0].
//   Uncertainty-aware slopes (ua = 1, 16-QAM only; ТЗ 004 Patch A, golden python/rxenh_fixed_ref.py::demap_soft_ua): the channel-estimate
//   error grows with the symbol energy, so with d = |x| - T:  L1 = (d * 57) >>> 6 ;  L0 = -x for d <= 0, else -sgn(x) * (T + ((d * 51) >>> 6)).
// Latency 8, throughput 1 bin/cycle, 4 DSP.   Golden: python/phy2_fixed_ref.py::demap_soft (bit-exact)
module phy_llr_demap
  import phy_pkg::*;
  import phy_soft_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic                   qpsk,
  input  logic                   ua,             // uncertainty-aware slopes (static per packet)
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
  logic v1, f1, l1, q1; logic signed [IQ_W-1:0] x1r, x1i;
  always_ff @(posedge clk) begin
    if (rst) v1 <= 1'b0; else v1 <= in_valid;
    f1 <= in_first; l1 <= in_last; q1 <= qpsk; x1r <= in_re; x1i <= in_im;
  end
  wire [15:0]       t1  = rd_data[28:13];
  wire [5:0]        gm1 = rd_data[12:7];
  wire signed [6:0] ge1 = rd_data[6:0];

  // S2a: |x| - T per axis
  logic va, fa, la, qa; logic signed [IQ_W-1:0] xar, xai; logic signed [16:0] dar, dai; logic [15:0] ta; logic [5:0] gma; logic signed [6:0] gea;
  always_ff @(posedge clk) begin
    if (rst) va <= 1'b0; else va <= v1;
    fa <= f1; la <= l1; qa <= q1; gma <= gm1; gea <= ge1; xar <= x1r; xai <= x1i; ta <= t1;
    dar <= (x1r[IQ_W-1] ? 17'(-x1r) : 17'(x1r)) - 17'($signed({1'b0, t1}));
    dai <= (x1i[IQ_W-1] ? 17'(-x1i) : 17'(x1i)) - 17'($signed({1'b0, t1}));
  end
  // uncertainty-aware terms: (d * 57) >>> 6 and T + ((d * 51) >>> 6)  (constant multipliers as shift-adds)
  function automatic logic signed [16:0] ua_mid(input logic signed [16:0] d);
    logic signed [23:0] p;
    p = (24'(d) <<< 6) - (24'(d) <<< 3) + 24'(d);                 // d * 57
    return 17'(p >>> 6);
  endfunction
  function automatic logic signed [16:0] ua_out(input logic signed [16:0] d, input logic [15:0] t);
    logic signed [23:0] p;
    p = (24'(d) <<< 5) + (24'(d) <<< 4) + (24'(d) <<< 1) + 24'(d);  // d * 51
    return 17'($signed({1'b0, t})) + 17'(p >>> 6);
  endfunction
  // S2b: the uncertainty-aware terms in a stage of their own (timing: three adders in front of the multiplier input otherwise)
  logic vb, fb, lb, qb; logic signed [IQ_W-1:0] xbr, xbi; logic signed [16:0] dbr, dbi, umr, umi, uor, uoi; logic [5:0] gmb; logic signed [6:0] geb;
  always_ff @(posedge clk) begin
    if (rst) vb <= 1'b0; else vb <= va;
    fb <= fa; lb <= la; qb <= qa; gmb <= gma; geb <= gea; xbr <= xar; xbi <= xai; dbr <= dar; dbi <= dai;
    umr <= ua_mid(dar); umi <= ua_mid(dai); uor <= ua_out(dar, ta); uoi <= ua_out(dai, ta);
  end
  // S2: axis values (17 bit signed)
  logic v2, f2, l2, q2; logic signed [16:0] a2 [4]; logic [5:0] gm2; logic signed [6:0] ge2;
  always_ff @(posedge clk) begin
    if (rst) v2 <= 1'b0; else v2 <= vb;
    f2 <= fb; l2 <= lb; q2 <= qb; gm2 <= gmb; ge2 <= geb;
    if (qb) begin                                   // QPSK: [I, Q, 0, 0], value * 9/8 (the missing factor 2 is taken from the shift)
      a2[0] <= -(17'(xbr) + 17'(xbr >>> 3));
      a2[1] <= -(17'(xbi) + 17'(xbi >>> 3));
      a2[2] <= '0;
      a2[3] <= '0;
    end else if (ua) begin
      a2[0] <= (dbr <= 0) ? -17'(xbr) : (xbr[IQ_W-1] ? uor : -uor);
      a2[1] <= umr;
      a2[2] <= (dbi <= 0) ? -17'(xbi) : (xbi[IQ_W-1] ? uoi : -uoi);
      a2[3] <= umi;
    end else begin
      a2[0] <= -17'(xbr);
      a2[1] <= dbr;
      a2[2] <= -17'(xbi);
      a2[3] <= dbi;
    end
  end

  // S3: products
  logic v3, f3, l3; logic signed [23:0] p3 [4]; logic signed [7:0] sh3;
  always_ff @(posedge clk) begin
    if (rst) v3 <= 1'b0; else v3 <= v2;
    f3 <= f2; l3 <= l2;
    for (int i = 0; i < 4; i++) p3[i] <= 24'(a2[i]) * 24'($signed({1'b0, gm2}));
    sh3 <= 8'(SH_C) - 8'(ge2) - (q2 ? 8'sd1 : 8'sd0);
  end

  // S4: rounding add
  logic v4, f4, l4; logic signed [39:0] p4 [4]; logic signed [7:0] sh4;
  always_ff @(posedge clk) begin
    if (rst) v4 <= 1'b0; else v4 <= v3;
    f4 <= f3; l4 <= l3; sh4 <= sh3;
    for (int i = 0; i < 4; i++)
      p4[i] <= (sh3 > 8'sd0) ? (40'(p3[i]) + (40'sd1 <<< (sh3 - 8'sd1))) : 40'(p3[i]);
  end

  // S5: shift
  logic v5, f5, l5; logic signed [39:0] p5 [4];
  always_ff @(posedge clk) begin
    if (rst) v5 <= 1'b0; else v5 <= v4;
    f5 <= f4; l5 <= l4;
    for (int i = 0; i < 4; i++) p5[i] <= (sh4 > 8'sd0) ? (p4[i] >>> sh4) : (p4[i] <<< (-sh4));
  end

  // S6: saturate
  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= v5;
    out_first <= f5; out_last <= l5;
    for (int i = 0; i < 4; i++) begin
      if (p5[i] > 40'sd31) out_llr[i] <= 6'sd31; else if (p5[i] < -40'sd31) out_llr[i] <= -6'sd31; else out_llr[i] <= p5[i][5:0];
    end
  end
endmodule
