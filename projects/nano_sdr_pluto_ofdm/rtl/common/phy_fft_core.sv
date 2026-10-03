// Module : phy_fft_core   N = 2^N_LOG point radix-2 DIF SDF FFT, streaming 1 sample/valid, output in BIT-REVERSED order.
// Contract: LATENCY (continuous valid) = (N-1) + sum(stage latencies) cycles from first input to first output;
//           output stream is `in_valid` delayed by that amount (frame f output overlaps frame f+1 input).
//           To flush the last frame, feed N additional (zero) samples.
// Data   : in 16-bit signed (sign extended to W internally), out W-bit signed (W = IQ_W+2 by default; see wrapper).
// Scale  : SHIFT_MASK bit s set -> stage s (0 = first, D=N/2) divides by 2 (round-half-up); else saturates.
//          Full 1/N scaling = all ones.
// DSP    : 4 per stage with D>=4 (N=2048: 9 stages = 36 DSP48E1).  TODO(opt): radix-2^2 / 3-mult to cut DSP.
// Golden : python/fft_ref.py::fft_fixed (bit-exact)
module phy_fft_core #(
  parameter int N_LOG      = 11,
  parameter int W          = 18,
  parameter int TWW        = 16,
  parameter int SHIFT_MASK = 0,
  parameter int IN_W       = 16
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic signed [IN_W-1:0] in_re,
  input  logic signed [IN_W-1:0] in_im,
  output logic                   out_valid,
  output logic signed [W-1:0]    out_re,
  output logic signed [W-1:0]    out_im
);
  localparam int LATENCY = phy_pkg::fft_core_latency(N_LOG);

  logic                v [N_LOG+1];
  logic signed [W-1:0] re [N_LOG+1];
  logic signed [W-1:0] im [N_LOG+1];

  assign v[0]  = in_valid;
  assign re[0] = W'(in_re);
  assign im[0] = W'(in_im);

  for (genvar s = 0; s < N_LOG; s++) begin : g_st
    phy_fft_stage #(.LOGD(N_LOG - 1 - s), .W(W), .TWW(TWW), .SHIFT((SHIFT_MASK >> s) & 1)) u_st (
      .clk, .rst,
      .in_valid(v[s]), .in_re(re[s]), .in_im(im[s]),
      .out_valid(v[s+1]), .out_re(re[s+1]), .out_im(im[s+1])
    );
  end

  assign out_valid = v[N_LOG];
  assign out_re    = re[N_LOG];
  assign out_im    = im[N_LOG];
endmodule
