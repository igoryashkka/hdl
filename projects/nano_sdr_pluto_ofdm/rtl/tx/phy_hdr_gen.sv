// Module : phy_hdr_gen   PHY header symbol generator (TX): one OFDM symbol of 1100 QPSK bins that carries MODE_ID and the packet length.
//   header word (16 bit) = {mode(1), nsyms(8), rsv(3) = 0, crc4(4)};  crc4 = CRC-4 (x^4 + x + 1, init 0) over the 12 bits before it.
//   Coded bits: the 16 header bits are repeated over all 2200 bits of the symbol (bit i = hdr[15 - (i mod 16)]) and XORed with a
//   PN sequence (15 bit LFSR, taps 14 / 13, seed HDR_SEED, one step per bit) so the symbol has no spectral lines (low PAPR).
//   Bin n carries bits 2n (I) and 2n+1 (Q); bit 1 = +HDR_AMP, bit 0 = -HDR_AMP (same convention as phy_qam_mapper QPSK).
//   The repetition (~137 copies) gives the receiver ~21 dB of processing gain: the header decodes where the payload cannot.
// Interface: start pulse (mode / nsyms sampled), then out_valid / out_ready for 1100 bins, busy until the last one is taken.
// Golden: python/hdr_ref.py
module phy_hdr_gen
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   start,
  input  logic                   mode,
  input  logic [7:0]             nsyms,
  output logic                   out_valid,
  input  logic                   out_ready,
  output logic signed [IQ_W-1:0] out_i,
  output logic signed [IQ_W-1:0] out_q,
  output logic                   busy
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

  logic [15:0] hdr;
  logic [14:0] lf;
  logic [10:0] n;           // bin counter
  logic [2:0]  pos;         // (n mod 8): bit pair index inside the 16 bit word
  logic        act;

  wire        s0 = lf[14] ^ lf[13];
  wire [14:0] lf1 = {lf[13:0], s0};
  wire        s1 = lf1[14] ^ lf1[13];
  wire        b0 = hdr[15 - 2 * int'(pos)]     ^ s0;
  wire        b1 = hdr[15 - 2 * int'(pos) - 1] ^ s1;

  assign out_valid = act;
  assign out_i     = b0 ? IQ_W'(HDR_AMP) : -IQ_W'(HDR_AMP);
  assign out_q     = b1 ? IQ_W'(HDR_AMP) : -IQ_W'(HDR_AMP);
  assign busy      = act;

  always_ff @(posedge clk) begin
    if (rst) begin act <= 1'b0; n <= '0; pos <= '0; lf <= HDR_SEED[14:0]; hdr <= '0; end
    else if (start && !act) begin
      hdr <= {mode, nsyms, 3'b000, crc4({mode, nsyms, 3'b000})};
      lf <= HDR_SEED[14:0]; n <= '0; pos <= '0; act <= 1'b1;
    end else if (act && out_ready) begin
      lf  <= {lf1[13:0], s1};
      pos <= pos + 3'd1;
      if (n == 11'(NUM_DATA_SC - 1)) begin act <= 1'b0; n <= '0; end
      else n <= n + 1'b1;
    end
  end
endmodule
