// Module : phy_scrambler  (also used as phy_descrambler -- additive scrambler is symmetric)
// Purpose: x^15+x^14+1 additive scrambler, 8 bits/cycle, MSB-first.
// Clock  : clk, sync active-high rst.   Latency = 1 cycle.  Throughput = 1 byte/cycle.
// Format : data unsigned 8 bit.  in_first (with valid) reloads SEED before processing that byte.
// Golden : python/scrambler_ref.py (bit-exact).
module phy_scrambler
  import phy_pkg::*;
#(
  parameter logic [14:0] SEED = SCR_SEED
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       in_valid,
  input  logic       in_first,
  input  logic       in_last,
  input  logic [7:0] in_data,
  output logic       out_valid,
  output logic       out_first,
  output logic       out_last,
  output logic [7:0] out_data
);
  localparam int LATENCY = 1;

  logic [14:0] lfsr;
  logic [14:0] lfsr_next;
  logic [7:0]  data_next;

  always_comb begin
    logic       fb;
    lfsr_next = in_first ? SEED : lfsr;
    data_next = '0;
    for (int i = 7; i >= 0; i--) begin
      fb           = lfsr_next[14] ^ lfsr_next[13];
      data_next[i] = in_data[i] ^ fb;
      lfsr_next    = {lfsr_next[13:0], fb};
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      lfsr      <= SEED;
      out_valid <= 1'b0;
      out_first <= 1'b0;
      out_last  <= 1'b0;
      out_data  <= '0;
    end else begin
      out_valid <= in_valid;
      out_first <= in_first & in_valid;
      out_last  <= in_last & in_valid;
      if (in_valid) begin
        lfsr     <= lfsr_next;
        out_data <= data_next;
      end
    end
  end
endmodule
