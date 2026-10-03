// Module : phy_dc_remove   leaky-integrator DC canceller for one real channel (instantiate twice: I and Q).
//   est = acc >>> K ; out = sat(x - est) ; acc += x - est      (time constant 2^K samples, valid-gated)
// Latency 1, throughput 1 sample/valid. acc is signed W+K+2 bits (no overflow). Golden: python/rx_blocks_ref.py::dc_remove
// A DC offset is periodic with every lag and would fire the Schmidl-Cox detector, hence this block is mandatory before it.
module phy_dc_remove #(
  parameter int W = 16,
  parameter int K = 10
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                in_valid,
  input  logic signed [W-1:0] in_data,
  output logic                out_valid,
  output logic signed [W-1:0] out_data
);
  localparam int AW = W + K + 2;
  logic signed [AW-1:0] acc;
  wire  signed [AW-1:0] est  = acc >>> K;
  wire  signed [AW-1:0] diff = AW'(in_data) - est;
  localparam logic signed [AW-1:0] HI = (AW'(1) <<< (W - 1)) - 1;
  localparam logic signed [AW-1:0] LO = -(AW'(1) <<< (W - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0; out_valid <= 1'b0; out_data <= '0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        acc      <= acc + diff;
        out_data <= (diff > HI) ? HI[W-1:0] : (diff < LO) ? LO[W-1:0] : diff[W-1:0];
      end
    end
  end
endmodule
