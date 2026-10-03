// Module : phy_ifft_2048   IFFT wrapper around phy_fft_core (swap-I/Q trick: ifft(x) = swap(fft(swap(x)))), output
//          saturated to IQ_W bits. Output in BIT-REVERSED order (consumed by phy_cp_insert).
// Scaling: SHIFT_MASK per stage (default 0x0FF: 8 divide-by-2 stages; full 1/N would be 0x7FF).
//          For 1100 loaded 16-QAM carriers (unit 4096) this gives time-domain rms ~1700, peaks < 8000 (16-bit safe).
// Latency = phy_fft_core LATENCY + 1 (output register). Throughput 1 sample/valid; flush with N-1 zero samples.
// Vendor IP note: self-contained radix-2 SDF core (no vendor IP); see phy_fft_core.sv for DSP/BRAM use.
// Golden: python/fft_ref.py::ifft_fixed + saturation to IQ_W.
module phy_ifft_2048
  import phy_pkg::*;
#(
  parameter int N_LOG      = $clog2(FFT_SIZE),
  parameter int SHIFT_MASK = 32'h0FF
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
  logic                core_valid;
  logic signed [W-1:0] core_re, core_im;

  phy_fft_core #(.N_LOG(N_LOG), .W(W), .SHIFT_MASK(SHIFT_MASK), .IN_W(IQ_W)) u_core (
    .clk, .rst, .in_valid, .in_re(in_im), .in_im(in_re),      // swap in
    .out_valid(core_valid), .out_re(core_re), .out_im(core_im)
  );
  localparam int LATENCY = fft_core_latency(N_LOG) + 1;

  localparam logic signed [W-1:0] HI = (W'(1) <<< (IQ_W - 1)) - 1;
  localparam logic signed [W-1:0] LO = -(W'(1) <<< (IQ_W - 1));

  function automatic logic signed [IQ_W-1:0] sat16(input logic signed [W-1:0] v);
    return (v > HI) ? HI[IQ_W-1:0] : (v < LO) ? LO[IQ_W-1:0] : v[IQ_W-1:0];
  endfunction

  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0;
    else     out_valid <= core_valid;
    out_re <= sat16(core_im);                                   // swap out
    out_im <= sat16(core_re);
  end
endmodule
