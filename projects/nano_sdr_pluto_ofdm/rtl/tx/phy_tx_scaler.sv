// Module : phy_tx_scaler   digital TX gain: out = sat16( round_half_up( x * gain / 2^GAIN_FRAC ) ), I and Q.
// gain: unsigned GAIN_W bits, GAIN_FRAC fractional bits (16384 = 1.0 with GAIN_FRAC=14, max ~4.0).
// Latency = 2 (product reg, round+saturate reg).  Throughput 1 sample/cycle, valid-gated.
// Golden: python/tx_ref.py::tx_scale (bit-exact)
module phy_tx_scaler
  import phy_pkg::*;
#(
  parameter int GAIN_W    = 16,
  parameter int GAIN_FRAC = 14
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic [GAIN_W-1:0]      gain,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 2;
  localparam int PW = IQ_W + GAIN_W + 1;
  logic signed [PW-1:0] p_re, p_im, r_re, r_im;
  logic                 v1;
  localparam logic signed [PW-1:0] RND = PW'(1) <<< (GAIN_FRAC - 1);
  localparam logic signed [PW-1:0] HI  = (PW'(1) <<< (IQ_W - 1)) - 1;
  localparam logic signed [PW-1:0] LO  = -(PW'(1) <<< (IQ_W - 1));

  always_comb begin
    r_re = (p_re + RND) >>> GAIN_FRAC;
    r_im = (p_im + RND) >>> GAIN_FRAC;
  end

  always_ff @(posedge clk) begin
    p_re <= PW'(in_re) * PW'($signed({1'b0, gain}));
    p_im <= PW'(in_im) * PW'($signed({1'b0, gain}));
    out_re <= (r_re > HI) ? HI[IQ_W-1:0] : (r_re < LO) ? LO[IQ_W-1:0] : r_re[IQ_W-1:0];
    out_im <= (r_im > HI) ? HI[IQ_W-1:0] : (r_im < LO) ? LO[IQ_W-1:0] : r_im[IQ_W-1:0];
    if (rst) begin v1 <= 1'b0; out_valid <= 1'b0; end
    else     begin v1 <= in_valid; out_valid <= v1; end
  end
endmodule
