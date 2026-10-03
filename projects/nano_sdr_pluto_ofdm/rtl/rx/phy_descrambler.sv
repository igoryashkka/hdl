// phy_descrambler: thin wrapper (additive scrambler is its own inverse). Latency = 1.
module phy_descrambler (
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
  phy_scrambler u_scr (.*);
endmodule
