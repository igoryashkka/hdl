// ***************************************************************************
// GFSK RX: FM discriminator with DC (carrier residue) removal. Pipelined, latency 3.
//   p = x[n] * conj(x[n-1]);  d = Im(p) ~ |p| * sin(dphi): the sign is the sign of the FSK tone.
//   DC is tracked with a one-pole average (512 samples ~ 17 bits at 19.2 kbit/s).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_discrim #(
  parameter int IN_W     = 16,
  parameter int DC_SHIFT = 9
) (
  input  logic                    clk,
  input  logic                    en,
  input  logic signed [IN_W-1:0]  i_in,
  input  logic signed [IN_W-1:0]  q_in,
  output logic signed [23:0]      d_out,       // DC-removed discriminator output
  output logic                    out_valid
);
  logic signed [IN_W-1:0] i1 = '0, q1 = '0;     // x[n-1]
  logic signed [39:0]     dc = '0;              // DC estimate, scaled by 2^16

  // stage 1: Im(x[n] conj(x[n-1])) = Q*I1 - I*Q1
  logic signed [2*IN_W:0] im_r;
  logic                   v1 = 1'b0;
  always_ff @(posedge clk) begin
    v1 <= 1'b0;
    if (en) begin
      im_r <= (2*IN_W+1)'(q_in) * (2*IN_W+1)'(i1) - (2*IN_W+1)'(i_in) * (2*IN_W+1)'(q1);
      i1   <= i_in;
      q1   <= q_in;
      v1   <= 1'b1;
    end
  end

  // stage 2: scale
  logic signed [23:0] d_r;
  logic               v2 = 1'b0;
  always_ff @(posedge clk) begin
    v2 <= v1;
    if (v1) d_r <= 24'(im_r >>> 14);
  end

  // stage 3: DC removal and running DC estimate
  always_ff @(posedge clk) begin
    out_valid <= v2;
    if (v2) begin
      d_out <= d_r - 24'(dc >>> 16);
      dc    <= dc + (((40'(d_r) <<< 16) - dc) >>> DC_SHIFT);
    end
  end
endmodule
