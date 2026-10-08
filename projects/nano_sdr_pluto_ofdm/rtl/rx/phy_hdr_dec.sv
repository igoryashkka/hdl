// Module : phy_hdr_dec   PHY header decoder (RX): soft-combines the repetition-coded header symbol (see phy_hdr_gen).
//   Input: the 1100 QPSK bins of the header symbol as two 6 bit LLRs per bin (positive = bit 0).  Every LLR is multiplied by the PN
//   sign of its bit position and added to the accumulator of (bit index mod 16); at the last bin the sign of each accumulator is a
//   header bit (negative = 1), then CRC-4 is checked.  Output pulse with o_ok (CRC), o_mode, o_nsyms, o_conf (min |acc|, diagnostics).
// Golden: python/hdr_ref.py
module phy_hdr_dec
  import phy_pkg::*;
(
  input  logic              clk,
  input  logic              rst,
  input  logic              in_valid,
  input  logic              in_first,
  input  logic              in_last,
  input  logic signed [5:0] in_llr0,
  input  logic signed [5:0] in_llr1,
  output logic              o_valid,
  output logic              o_ok,
  output logic              o_mode,
  output logic [7:0]        o_nsyms,
  output logic [13:0]       o_conf
);
  function automatic logic [3:0] crc4(input logic [11:0] d);
    logic [3:0] c;
    c = 4'd0;
    for (int i = 11; i >= 0; i--) begin
      logic fb;
      fb = c[3] ^ d[i];
      c  = {c[2:0], 1'b0} ^ (fb ? 4'b0011 : 4'b0000);
    end
    return c;
  endfunction

  logic signed [13:0] acc [16];
  logic [14:0] lf;
  logic [3:0]  pos;
  logic        fin, lastq;

  wire  [14:0] lf_c  = in_first ? HDR_SEED[14:0] : lf;
  wire  [3:0]  pos_c = in_first ? 4'd0 : pos;
  wire         s0    = lf_c[14] ^ lf_c[13];
  wire  [14:0] lf1   = {lf_c[13:0], s0};
  wire         s1    = lf1[14] ^ lf1[13];
  wire  signed [13:0] v0 = s0 ? -14'(in_llr0) : 14'(in_llr0);
  wire  signed [13:0] v1 = s1 ? -14'(in_llr1) : 14'(in_llr1);

  always_ff @(posedge clk) begin
    fin <= 1'b0;
    if (rst) begin
      lf <= HDR_SEED[14:0]; pos <= '0;
      for (int j = 0; j < 16; j++) acc[j] <= '0;
    end else if (in_valid) begin
      for (int j = 0; j < 16; j++)
        acc[j] <= (in_first ? 14'sd0 : acc[j]) + ((4'(j) == pos_c) ? v0 : (4'(j) == pos_c + 4'd1) ? v1 : 14'sd0);
      lf  <= {lf1[13:0], s1};
      pos <= pos_c + 4'd2;
      fin <= in_last;
    end
  end

  // result pipeline (timing): sign bits / |acc| registered, 4 group minima, final minimum; CRC check in the same stages
  logic [15:0] h1, h2; logic [13:0] ab1 [16]; logic [13:0] gm2 [4]; logic fin1, fin2;
  always_ff @(posedge clk) begin
    fin1 <= fin; fin2 <= fin1;
    for (int j = 0; j < 16; j++) begin
      h1[15 - j] <= acc[j][13];
      ab1[j] <= acc[j][13] ? 14'(-acc[j]) : 14'(acc[j]);
    end
    h2 <= h1;
    for (int g = 0; g < 4; g++) begin
      logic [13:0] m;
      m = ab1[4*g];
      for (int k = 1; k < 4; k++) if (ab1[4*g+k] < m) m = ab1[4*g+k];
      gm2[g] <= m;
    end
    o_valid <= fin2;
    if (fin2) begin
      logic [13:0] mn;
      mn = gm2[0];
      for (int g = 1; g < 4; g++) if (gm2[g] < mn) mn = gm2[g];
      o_ok    <= (crc4(h2[15:4]) == h2[3:0]);
      o_mode  <= h2[15];
      o_nsyms <= h2[14:7];
      o_conf  <= mn;
    end
  end
endmodule
