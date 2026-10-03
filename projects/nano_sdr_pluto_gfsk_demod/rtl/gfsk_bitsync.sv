// ***************************************************************************
// GFSK RX: symbol timing recovery and hard decision.
//   Bit-clock phase accumulator in units of one bit (2^32 = 1 bit period).
//   At each sign change of the discriminator the phase is pulled 1/4 of the way
//   toward the bit edge (simplified Mueller-type loop, applied only within +-1/4 bit).
//   A bit is sampled when the phase crosses one half (mid-bit).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_bitsync #(
  parameter logic [31:0] BIT_INC = 32'h08bcf64e   // 19.2 kbit/s at 562.5 kS/s
) (
  input  logic                clk,
  input  logic                en,                 // discriminator strobe (562.5 kS/s)
  input  logic signed [23:0]  d_in,
  output logic                bit_valid,
  output logic                bit_out
);
  logic [31:0] ph = '0;
  logic        prev = 1'b0;

  logic        cur;
  logic        edge_now;
  logic [31:0] ph_next;
  logic signed [31:0] err;
  logic        within_quarter;
  logic [31:0] ph_new;

  always_comb begin
    cur            = (d_in > 0);
    edge_now       = (cur != prev);
    ph_next        = ph + BIT_INC;
    err            = $signed(ph);                  // the edge should land on phase 0
    within_quarter = (err <  32'sd536870912) && (err > -32'sd536870912);
    ph_new         = (edge_now && within_quarter) ? (ph_next - 32'(err >>> 2)) : ph_next;
  end

  always_ff @(posedge clk) begin
    bit_valid <= 1'b0;
    if (en) begin
      prev <= cur;
      ph   <= ph_new;
      // mid-bit sample: the phase crosses one half (bit 31 rises)
      if (!ph[31] && ph_next[31]) begin
        bit_valid <= 1'b1;
        bit_out   <= cur;
      end
    end
  end
endmodule
