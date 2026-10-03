// Module : phy_fft_2048   forward FFT wrapper around phy_fft_core, output saturated to IQ_W bits, BIT-REVERSED order
//          (use phy_cp_insert with CP=0, BITREV=1 to obtain natural order, see phy_rx_fft).
// Scaling: SHIFT_MASK per stage (RX default 0x00F: 4 divide-by-2 stages; ADC-level input of ~600 rms gives bins of ~2k).
// Latency = fft_core_latency(N_LOG) + 1; flush with N-1 zero samples (phy_rx_window does that).
// Golden: python/rx_fixed_ref.py::rx_fft (natural order after the reorder buffer).
module phy_fft_2048
  import phy_pkg::*;
#(
  parameter int N_LOG      = $clog2(FFT_SIZE),
  parameter int SHIFT_MASK = 32'h00F
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int W = IQ_W + 2;
  localparam int LATENCY = fft_core_latency(N_LOG) + 1;
  logic                core_valid;
  logic signed [W-1:0] core_re, core_im;

  phy_fft_core #(.N_LOG(N_LOG), .W(W), .SHIFT_MASK(SHIFT_MASK), .IN_W(IQ_W)) u_core (
    .clk, .rst, .in_valid, .in_re, .in_im, .out_valid(core_valid), .out_re(core_re), .out_im(core_im)
  );

  localparam logic signed [W-1:0] HI = (W'(1) <<< (IQ_W - 1)) - 1;
  localparam logic signed [W-1:0] LO = -(W'(1) <<< (IQ_W - 1));
  function automatic logic signed [IQ_W-1:0] sat16(input logic signed [W-1:0] v);
    return (v > HI) ? HI[IQ_W-1:0] : (v < LO) ? LO[IQ_W-1:0] : v[IQ_W-1:0];
  endfunction

  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= core_valid;
    out_re <= sat16(core_re);
    out_im <= sat16(core_im);
  end
endmodule
