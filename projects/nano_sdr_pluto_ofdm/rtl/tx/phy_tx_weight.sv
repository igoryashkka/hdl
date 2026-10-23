// Module : phy_tx_weight   per-subcarrier transmit weight for beamforming (TestTask006), placed before the IFFT of one channel.
//   W[k] = A * exp(j*(phi + 2*pi*ks*tau/N)), ks = k (k < N/2) or k - N; bins arrive in natural order 0..N-1 with gaps.
//   phase32 = (phase << 16) + ks*tau*2^13 (mod 2^32), table index phase32[31:20] (phy_sincos, 12 bit);
//   cw = (cos*amp + 2^14) >>> 15, sw = (sin*amp + 2^14) >>> 15; y = x*(cw + j sw) (phy_complex_mult: round half up, sat 16).
//   tau: 1/256 sample, tau > 0 ADVANCES the signal. amp: Q1.15 (0..32767). phase: 2^16 = 2*pi.
//   mode: 0 = bypass (y = x, bit-exact), 1 = weight, 2/3 = mute (y = 0). Parameters are latched on `load` (frame start)
//   and stay constant for the whole frame. Bin counter: counts in_valid modulo N, realigned by rst | bin_rst (= IFFT reset).
// Latency = 12 cycles (input reg 1, ks 1, ks*tau 1, phase add 1, sincos 2, cos/sin*amp 1, coefficient round 1, complex mult 4),
//   all modes; throughput 1 bin/cycle, valid delayed alongside. DSP: 7 (1 + 2 + 4). ROM: phy_sincos.
// Golden: python/bf_ref.py::apply_weight (bit-exact).
module phy_tx_weight
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   bin_rst,
  input  logic                   load,
  input  logic [1:0]             mode_i,
  input  logic [15:0]            amp_i,
  input  logic [15:0]            phase_i,
  input  logic signed [16:0]     tau_i,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 12;
  localparam int N_LOG = $clog2(FFT_SIZE);

  logic [1:0]          mode_r;
  logic [15:0]         amp_r, phase_r;
  logic signed [16:0]  tau_r;
  always_ff @(posedge clk) begin
    if (rst) begin mode_r <= 2'd0; amp_r <= '0; phase_r <= '0; tau_r <= '0; end
    else if (load) begin mode_r <= mode_i; amp_r <= amp_i; phase_r <= phase_i; tau_r <= tau_i; end
  end

  // ---- s0: input register + bin index
  logic [N_LOG-1:0]      cnt, k0;
  logic                  v0;
  logic signed [IQ_W-1:0] re0, im0;
  always_ff @(posedge clk) begin
    re0 <= in_re; im0 <= in_im; k0 <= cnt;
    if (rst || bin_rst) begin cnt <= '0; v0 <= 1'b0; end
    else begin
      v0 <= in_valid;
      if (in_valid) cnt <= cnt + 1'b1;
    end
  end

  // ---- s1..s3: phase = (phase << 16) + ks*tau << 13
  logic signed [N_LOG:0]    ks1;
  logic signed [N_LOG+17:0] prod2;
  logic [31:0]              ph3;
  always_ff @(posedge clk) begin
    ks1   <= k0[N_LOG-1] ? $signed({1'b1, k0}) : $signed({1'b0, k0});     // k - N for k >= N/2
    prod2 <= ks1 * tau_r;
    ph3   <= {phase_r, 16'd0} + (32'(prod2) << 13);                        // widen first: the product is taken mod 2^32
  end

  // ---- s4..s5: sin/cos
  logic signed [15:0] c5, s5;
  phy_sincos u_sc (.clk, .rst, .in_valid(1'b1), .idx(ph3[31:20]), .out_valid(), .cos_o(c5), .sin_o(s5));

  // ---- s6..s7: coefficient = (cos, sin) * amp, rounded to Q1.15
  logic signed [32:0] pc6, ps6;
  logic signed [15:0] cw7, sw7;
  wire  signed [32:0] pc_r = (pc6 + 33'sd16384) >>> 15;
  wire  signed [32:0] ps_r = (ps6 + 33'sd16384) >>> 15;
  always_ff @(posedge clk) begin
    pc6 <= c5 * $signed({1'b0, amp_r});
    ps6 <= s5 * $signed({1'b0, amp_r});
    cw7 <= pc_r[15:0];
    sw7 <= ps_r[15:0];
  end

  // ---- data delay s0 -> s7, valid delay s0 -> s11
  logic signed [IQ_W-1:0] dre [7], dim [7];
  logic [10:0]            vd;
  always_ff @(posedge clk) begin
    dre[0] <= re0; dim[0] <= im0;
    for (int i = 1; i < 7; i++) begin dre[i] <= dre[i-1]; dim[i] <= dim[i-1]; end
    if (rst) vd <= '0; else vd <= {vd[9:0], v0};
  end

  // ---- s8..s11: complex multiply, bypass path delayed by the same 4 cycles
  logic signed [IQ_W-1:0] m_re, m_im;
  phy_complex_mult #(.AW(IQ_W), .BW(16), .FRAC(15)) u_mult (
    .clk, .rst, .in_valid(1'b1), .a(dre[6]), .b(dim[6]), .c(cw7), .d(sw7), .out_valid(), .out_i(m_re), .out_q(m_im)
  );
  logic signed [IQ_W-1:0] bre [4], bim [4];
  always_ff @(posedge clk) begin
    bre[0] <= dre[6]; bim[0] <= dim[6];
    for (int i = 1; i < 4; i++) begin bre[i] <= bre[i-1]; bim[i] <= bim[i-1]; end
  end

  assign out_valid = vd[10];
  assign out_re = (mode_r == 2'd0) ? bre[3] : (mode_r == 2'd1) ? m_re : '0;
  assign out_im = (mode_r == 2'd0) ? bim[3] : (mode_r == 2'd1) ? m_im : '0;
endmodule
