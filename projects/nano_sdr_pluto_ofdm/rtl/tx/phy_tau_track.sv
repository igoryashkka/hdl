// Module : phy_tau_track   transmit delay that follows the sample-clock offset (TestTask006 rho).
//   acc (48 bit, 2^-32 sample) = tau_set << 24 on `set` (has priority); acc += sign_ext(rho) on every DAC strobe otherwise.
//   tau_now = sat16(acc >>> 24) in 1/256 sample, combinational from the register (valid the cycle after set / strobe).
// Golden: python/bf_ref.py::tau_used (bit-exact, without tick_adj).
module phy_tau_track (
  input  logic               clk,
  input  logic               rst,
  input  logic               strobe,
  input  logic               set,
  input  logic signed [15:0] tau_set,
  input  logic signed [31:0] rho,
  output logic signed [15:0] tau_now
);
  logic signed [47:0] acc;
  always_ff @(posedge clk) begin
    if (rst) acc <= '0;
    else if (set) acc <= {{8{tau_set[15]}}, tau_set, 24'd0};
    else if (strobe) acc <= acc + 48'(rho);
  end
  wire signed [23:0] hi = acc[47:24];
  assign tau_now = (hi > 24'sd32767) ? 16'sh7FFF : (hi < -24'sd32768) ? 16'sh8000 : hi[15:0];
endmodule
