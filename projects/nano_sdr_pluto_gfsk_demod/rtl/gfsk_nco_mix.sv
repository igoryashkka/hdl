// ***************************************************************************
// GFSK RX: frequency translation. y[n] = x[n] * exp(-j*2*pi*fc*n/fs)
//   32-bit phase accumulator, 1024-entry cos/sin table (gfsk_tables_pkg::COS_SIN_LUT, Q1.15).
//   Pipelined: ROM read -> products -> sums (latency 3).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_nco_mix #(
  parameter int IN_W = 16
) (
  input  logic                    clk,
  input  logic                    en,          // one input sample per strobe
  input  logic signed [IN_W-1:0]  i_in,
  input  logic signed [IN_W-1:0]  q_in,
  input  logic        [31:0]      phase_inc,   // round(fc/fs * 2^32), two's complement
  output logic signed [IN_W-1:0]  i_out,
  output logic signed [IN_W-1:0]  q_out,
  output logic                    out_valid
);
  localparam logic [15:0] LUT [0:2047] = gfsk_tables_pkg::COS_SIN_LUT;   // interleaved {cos, sin}
  logic [31:0] phase = '0;

  // stage 1: phase advance and table read
  logic signed [15:0]     c_r, s_r;
  logic signed [IN_W-1:0] i_d1, q_d1;
  logic                   v_d1 = 1'b0;
  always_ff @(posedge clk) begin
    v_d1 <= 1'b0;
    if (en) begin
      phase <= phase + phase_inc;
      c_r   <= $signed(LUT[{phase[31:22], 1'b0}]);
      s_r   <= $signed(LUT[{phase[31:22], 1'b1}]);
      i_d1  <= i_in;
      q_d1  <= q_in;
      v_d1  <= 1'b1;
    end
  end

  // stage 2: products (I*C, Q*S, Q*C, I*S)
  logic signed [IN_W+15:0] ic, qs, qc, is_;
  logic                    v_d2 = 1'b0;
  always_ff @(posedge clk) begin
    v_d2 <= v_d1;
    if (v_d1) begin
      ic  <= i_d1 * c_r;
      qs  <= q_d1 * s_r;
      qc  <= q_d1 * c_r;
      is_ <= i_d1 * s_r;
    end
  end

  // stage 3: (I + jQ)(C - jS) = (I*C + Q*S) + j(Q*C - I*S), then >> 15
  always_ff @(posedge clk) begin
    out_valid <= v_d2;
    if (v_d2) begin
      i_out <= IN_W'((ic + qs) >>> 15);
      q_out <= IN_W'((qc - is_) >>> 15);
    end
  end
endmodule
