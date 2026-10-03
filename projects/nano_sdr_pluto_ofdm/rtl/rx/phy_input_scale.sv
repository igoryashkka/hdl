// Module : phy_input_scale   power-of-two digital gain for one real channel (instantiate for I and Q), used by the AGC.
//   sh > 0 : x << sh (saturating) ; sh < 0 : round-half-up arithmetic >> -sh ; sh = 0 : passthrough.
// sh is a signed SH_W-bit control (static or slowly varying). Latency 1, valid-gated.  Golden: rx_blocks_ref.py::input_scale
module phy_input_scale #(
  parameter int W    = 16,
  parameter int SH_W = 4
) (
  input  logic                clk,
  input  logic                rst,
  input  logic signed [SH_W-1:0] sh,
  input  logic                in_valid,
  input  logic signed [W-1:0] in_data,
  output logic                out_valid,
  output logic signed [W-1:0] out_data
);
  localparam int EW = W + (1 << (SH_W - 1));          // wide enough for the largest left shift
  localparam logic signed [EW-1:0] HI = (EW'(1) <<< (W - 1)) - 1;
  localparam logic signed [EW-1:0] LO = -(EW'(1) <<< (W - 1));
  logic signed [EW-1:0] r;
  always_comb begin
    if (sh >= 0)      r = EW'(in_data) <<< sh;
    else              r = (EW'(in_data) + (EW'(1) <<< (-sh - 1))) >>> (-sh);
  end
  always_ff @(posedge clk) begin
    if (rst) begin out_valid <= 1'b0; out_data <= '0; end
    else begin
      out_valid <= in_valid;
      if (in_valid) out_data <= (r > HI) ? HI[W-1:0] : (r < LO) ? LO[W-1:0] : r[W-1:0];
    end
  end
endmodule
