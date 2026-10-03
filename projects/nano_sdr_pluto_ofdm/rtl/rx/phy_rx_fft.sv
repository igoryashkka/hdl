// Module : phy_rx_fft   RX FFT chain: phy_fft_2048 + frame buffer (bit-reverse reorder, CP=0, NB banks).
// Input : windows of N samples from phy_rx_window (valid-gated; flush zeros included).  core_rst (pulse) soft-resets the SDF
//         stage counters between packets (after the last frame has been written, like on the TX side).
// Output: natural-order frames (bin 0 .. N-1) with out_valid/out_ready, out_first/out_last per frame.
// frame_written pulses when a frame is stored; overflow latches if a frame arrives while all banks are full.
// Golden: python/rx_fixed_ref.py::rx_fft (bit-exact), tb_phy_rx_fft.
module phy_rx_fft
  import phy_pkg::*;
#(
  parameter int N_LOG      = $clog2(FFT_SIZE),
  parameter int SHIFT_MASK = 32'h00F,
  parameter int NB         = 2
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   core_rst,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   frame_written,
  output logic                   overflow,
  output logic                   out_valid,
  input  logic                   out_ready,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im,
  output logic                   out_first,
  output logic                   out_last,
  output logic                   frame_done
);
  logic                   f_valid;
  logic signed [IQ_W-1:0] f_re, f_im;
  logic                   frame_ok;

  phy_fft_2048 #(.N_LOG(N_LOG), .SHIFT_MASK(SHIFT_MASK)) u_fft (
    .clk, .rst(rst | core_rst), .in_valid, .in_re, .in_im, .out_valid(f_valid), .out_re(f_re), .out_im(f_im)
  );

  phy_cp_insert #(.N_LOG(N_LOG), .CP(0), .BITREV(1'b1), .NB(NB)) u_buf (
    .clk, .rst, .in_valid(f_valid), .in_re(f_re), .in_im(f_im),
    .frame_ok, .frame_written, .sym_done(frame_done), .overflow,
    .out_valid, .out_ready, .out_re, .out_im, .out_first, .out_last
  );
endmodule
