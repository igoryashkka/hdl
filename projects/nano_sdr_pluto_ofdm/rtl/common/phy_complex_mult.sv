// Module : phy_complex_mult   (a + jb) * (c + jd), pipelined, 4 real multipliers (maps to 4 DSP48E1).
// I = a*c - b*d ; Q = a*d + b*c ; result = round_half_up(. / 2^15) saturated to AW bits.
// Formats: a,b signed AW (data); c,d signed BW (Q1.15 coefficient, BW<=18).  Product AW+BW, sum +1.
// Latency = 4 cycles (input reg / product reg / sum+round reg / shift+saturate reg).  Throughput 1 sample/cycle.
// No reset on the datapath (valid is reset); data is don't-care while valid=0.
// Golden: python/fft_ref.py::cmul   Verification: via tb_phy_fft_core (bit-exact).
module phy_complex_mult #(
  parameter int AW = 18,
  parameter int BW = 16,
  parameter int FRAC = 15
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                in_valid,
  input  logic signed [AW-1:0] a,
  input  logic signed [AW-1:0] b,
  input  logic signed [BW-1:0] c,
  input  logic signed [BW-1:0] d,
  output logic                out_valid,
  output logic signed [AW-1:0] out_i,
  output logic signed [AW-1:0] out_q
);
  localparam int LATENCY = 4;
  localparam int PW = AW + BW;          // product width
  localparam int SW = PW + 2;           // sum + rounding constant headroom

  logic signed [AW-1:0] a_q, b_q;
  logic signed [BW-1:0] c_q, d_q;
  logic signed [PW-1:0] p_ac, p_bd, p_ad, p_bc;
  logic                 v1, v2, v3;

  localparam logic signed [SW-1:0] ROUND = SW'(1) <<< (FRAC - 1);
  localparam logic signed [SW-1:0] HI    = (SW'(1) <<< (AW - 1)) - 1;
  localparam logic signed [SW-1:0] LO    = -(SW'(1) <<< (AW - 1));

  logic signed [SW-1:0] re_full, im_full;
  logic signed [SW-1:0] re_sh, im_sh;

  always_comb begin
    re_sh = re_full >>> FRAC;
    im_sh = im_full >>> FRAC;
  end

  always_ff @(posedge clk) begin
    a_q <= a; b_q <= b; c_q <= c; d_q <= d;
    p_ac <= a_q * c_q;
    p_bd <= b_q * d_q;
    p_ad <= a_q * d_q;
    p_bc <= b_q * c_q;
    re_full <= SW'(p_ac) - SW'(p_bd) + ROUND;
    im_full <= SW'(p_ad) + SW'(p_bc) + ROUND;
    out_i <= (re_sh > HI) ? HI[AW-1:0] : (re_sh < LO) ? LO[AW-1:0] : re_sh[AW-1:0];
    out_q <= (im_sh > HI) ? HI[AW-1:0] : (im_sh < LO) ? LO[AW-1:0] : im_sh[AW-1:0];
  end

  always_ff @(posedge clk) begin
    if (rst) begin v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; out_valid <= 1'b0; end
    else     begin v1 <= in_valid; v2 <= v1; v3 <= v2; out_valid <= v3; end
  end
endmodule
