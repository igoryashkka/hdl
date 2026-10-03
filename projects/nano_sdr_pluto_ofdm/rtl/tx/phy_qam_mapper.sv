// Module : phy_qam_mapper  Gray-coded square QAM (4/16/64), parameter ORDER.
// Input  : in_bits = {I g0..g(m-1), Q g0..g(m-1)}, g0 = MSB.
// Output : signed IQ_W-bit I/Q, level = UNIT*(2*idx-(M-1)); UNIT*(M-1) < 2^(IQ_W-1) so no saturation.
// Latency = 1, throughput 1 symbol/cycle.  Golden: python/qam_ref.py (bit-exact)
module phy_qam_mapper
  import phy_pkg::*;
#(
  parameter int ORDER = QAM_ORDER,
  parameter int UNIT  = QAM_UNIT
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     in_valid,
  input  logic                     in_last,
  input  logic [$clog2(ORDER)-1:0] in_bits,
  output logic                     out_valid,
  output logic                     out_last,
  output logic signed [IQ_W-1:0]   out_i,
  output logic signed [IQ_W-1:0]   out_q
);
  localparam int LATENCY = 1;
  localparam int BPS = $clog2(ORDER);
  localparam int M   = BPS / 2;
  localparam int LV  = 1 << M;

  function automatic logic signed [IQ_W-1:0] axis_level(input logic [M-1:0] g);
    logic [M-1:0] b;
    int           idx;
    b = g;
    for (int k = 1; k < M; k++) b[M-1-k] = b[M-k] ^ g[M-1-k];  // gray -> binary, MSB first
    idx = int'(b);
    return IQ_W'(UNIT * (2 * idx - (LV - 1)));
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      out_valid <= 1'b0;
      out_last  <= 1'b0;
      out_i     <= '0;
      out_q     <= '0;
    end else begin
      out_valid <= in_valid;
      out_last  <= in_valid & in_last;
      if (in_valid) begin
        out_i <= axis_level(in_bits[BPS-1:M]);
        out_q <= axis_level(in_bits[M-1:0]);
      end
    end
  end
endmodule
