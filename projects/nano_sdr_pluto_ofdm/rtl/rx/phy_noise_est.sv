// Module : phy_noise_est   noise power from the unused guard bins of one FFT frame (natural-order stream of FFT_SIZE bins).
//   S = sum over bins GUARD_LO..GUARD_HI of (re^2 + im^2) of the frame marked by `en` (sampled at in_first), then
//   lg_nu = lgcode(S) + CNU  (log2 * 32 code of nu = 0.9 * S / 649, i.e. the noise term of the MMSE denominator |G|^2 + nu).
//   `nu_valid` pulses ~8 cycles after the last bin of the frame.  lg code of S == 0 is -1000 (+ CNU).
// DSP: 2.   Golden: python/phy2_fixed_ref.py::noise_code (bit-exact)
module phy_noise_est
  import phy_pkg::*;
  import phy_soft_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   en,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   nu_valid,
  output logic signed [12:0]     lg_nu,
  output logic [40:0]            noise_sum
);
  logic [10:0] cnt;
  logic        act;                                   // current frame is the one to measure
  wire  [10:0] cur = in_first ? 11'd0 : cnt;
  wire         act_cur = in_first ? en : act;
  always_ff @(posedge clk) begin
    if (rst) begin cnt <= '0; act <= 1'b0; end
    else if (in_valid) begin cnt <= cur + 1'b1; act <= act_cur; end
  end

  // S1: operand registers + guard / last flags
  logic v1, g1, l1; logic signed [IQ_W-1:0] r1, i1;
  always_ff @(posedge clk) begin
    if (rst) begin v1 <= 1'b0; g1 <= 1'b0; l1 <= 1'b0; end
    else begin
      v1 <= in_valid & act_cur;
      g1 <= (cur >= 11'(GUARD_LO)) && (cur <= 11'(GUARD_HI));
      l1 <= (cur == 11'(FFT_SIZE - 1));
    end
    r1 <= in_re; i1 <= in_im;
  end
  // S2: squares
  logic v2, g2, l2; logic [31:0] sr2, si2;
  always_ff @(posedge clk) begin
    if (rst) begin v2 <= 1'b0; g2 <= 1'b0; l2 <= 1'b0; end else begin v2 <= v1; g2 <= g1; l2 <= l1; end
    sr2 <= 32'(r1) * 32'(r1); si2 <= 32'(i1) * 32'(i1);
  end
  // S3: accumulate; frame end -> finish pipeline
  logic [40:0] acc;
  logic        fin1;
  logic        first_g;
  always_ff @(posedge clk) begin
    fin1 <= 1'b0;
    if (rst) acc <= '0;
    else if (v2) begin
      acc <= ((acc & {41{~first_g}}) ) + (g2 ? 41'(sr2) + 41'(si2) : 41'd0);
      if (l2) fin1 <= 1'b1;
    end
  end
  // first_g = no guard bin seen yet in this frame: the accumulator restarts from 0
  always_ff @(posedge clk) begin
    if (rst) first_g <= 1'b1;
    else if (v2) begin
      if (g2) first_g <= 1'b0;
      if (l2) first_g <= 1'b1;
    end
  end

  // log code: priority encode, fraction, table
  logic [5:0]  p1; logic z1; logic [40:0] s1; logic fin2;
  always_ff @(posedge clk) begin
    p1 <= '0;
    for (int b = 0; b < 41; b++) if (acc[b]) p1 <= 6'(b);
    z1 <= (acc == 41'd0); s1 <= acc; fin2 <= fin1;
  end
  logic [4:0] fr2; logic [5:0] p2; logic z2; logic [40:0] s2; logic fin3;
  always_ff @(posedge clk) begin
    fr2 <= ((46'(s1) << LGMB) >> p1);
    p2 <= p1; z2 <= z1; s2 <= s1; fin3 <= fin2;
  end
  always_ff @(posedge clk) begin
    if (rst) nu_valid <= 1'b0; else nu_valid <= fin3;
    if (fin3) begin
      lg_nu <= z2 ? 13'(-1000 + CNU) : 13'(int'(p2) * LGF + int'(LGT_ROM[fr2]) + CNU);
      noise_sum <= s2;
    end
  end
endmodule
