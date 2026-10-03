// Module : phy_nco_mixer   32-bit phase-accumulator NCO + complex mixer: y = x * exp(+j*phase_n), phase_n = n*inc (2^32 = 2*pi).
//   Phase advances on in_valid; ph_clr (pulse) restarts the phase at 0 for the next sample. For CFO correction the
//   controller loads inc = -angle(P)/L (python/sync_ref.py).  Table: 1024-entry quarter-wave cos (midpoint sampled, Q1.15),
//   12 phase bits (spur < -60 dBc, phase error < 0.05 deg), table in phy_sincos.   Output = round-half-up(x*cs >> 15), saturated to 16 bit.
// Latency = 7 cycles (phase reg 1, table 1, quadrant mux 1, phy_complex_mult 4); throughput 1 sample/cycle, valid-gated phase.
// DSP: 4.  BRAM/LUT: 2 x 1024 x 16 ROM.   Golden: python/rx_blocks_ref.py::nco_mix (bit-exact)
module phy_nco_mixer #(
  parameter int W = 16
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [31:0]         inc,
  input  logic                ph_clr,
  input  logic                in_valid,
  input  logic signed [W-1:0] in_i,
  input  logic signed [W-1:0] in_q,
  output logic                out_valid,
  output logic signed [W-1:0] out_i,
  output logic signed [W-1:0] out_q
);
  localparam int LATENCY = 7;
  localparam int AW = 10;

  // ---- stage 0: phase accumulator
  logic [31:0]  ph;
  logic         clr_pending;
  logic [11:0]  idx0;
  logic         v0;
  logic signed [W-1:0] i0, q0;
  wire  [31:0]  ph_use = clr_pending ? 32'd0 : ph;
  always_ff @(posedge clk) begin
    if (rst) begin ph <= '0; clr_pending <= 1'b0; v0 <= 1'b0; end
    else begin
      v0 <= in_valid;
      if (ph_clr) clr_pending <= 1'b1;
      if (in_valid) begin
        ph <= ph_use + inc; clr_pending <= 1'b0;
        idx0 <= ph_use[31:20];
        i0 <= in_i; q0 <= in_q;
      end
    end
  end

  // ---- stages 1-2: sin/cos table (phy_sincos, 2 cycles) with the data delayed alongside
  logic signed [15:0] c2, s2;
  logic        v2;
  logic signed [W-1:0] i1, q1, i2, q2;
  phy_sincos u_sc (.clk, .rst, .in_valid(v0), .idx(idx0), .out_valid(v2), .cos_o(c2), .sin_o(s2));
  always_ff @(posedge clk) begin
    i1 <= i0; q1 <= q0; i2 <= i1; q2 <= q1;
  end

  // ---- stages 3..6: complex multiplier (x * (c + j s))
  phy_complex_mult #(.AW(W), .BW(16), .FRAC(15)) u_mult (
    .clk, .rst, .in_valid(v2), .a(i2), .b(q2), .c(c2), .d(s2),
    .out_valid, .out_i, .out_q
  );
endmodule
