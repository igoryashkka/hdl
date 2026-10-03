// ***************************************************************************
// GFSK RX: 15-tap FIR low-pass (150 kHz) on the decimated IQ (562.5 kS/s).
//   Real symmetric coefficients, Q1.15 (gfsk_tables_pkg::FIR15_TAPS); I and Q separately.
//   Pipelined: products register -> two partial sums register -> output register (latency 3).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_fir #(
  parameter int IN_W = 16,
  parameter int TAPS = 15
) (
  input  logic                    clk,
  input  logic                    en,          // decimated sample strobe
  input  logic signed [IN_W-1:0]  i_in,
  input  logic signed [IN_W-1:0]  q_in,
  output logic signed [IN_W-1:0]  i_out,
  output logic signed [IN_W-1:0]  q_out,
  output logic                    out_valid
);
  localparam logic signed [15:0] h [0:TAPS-1] = gfsk_tables_pkg::FIR15_TAPS;
  logic signed [IN_W-1:0] xi [0:TAPS-1] = '{default: '0};   // xi[0] = newest; zeroed, or X leaks
  logic signed [IN_W-1:0] xq [0:TAPS-1] = '{default: '0};   // into the discriminator's DC average

  // stage A: products (the tap window before this sample is shifted in)
  logic signed [31:0] pi [0:TAPS-1];
  logic signed [31:0] pq [0:TAPS-1];
  logic               va = 1'b0;
  always_ff @(posedge clk) begin
    va <= 1'b0;
    if (en) begin
      pi[0] <= 32'(h[0]) * 32'(i_in);
      pq[0] <= 32'(h[0]) * 32'(q_in);
      for (int k = 1; k < TAPS; k++) begin
        pi[k] <= 32'(h[k]) * 32'(xi[k-1]);
        pq[k] <= 32'(h[k]) * 32'(xq[k-1]);
      end
      xi[0] <= i_in;
      xq[0] <= q_in;
      for (int k = 1; k < TAPS; k++) begin
        xi[k] <= xi[k-1];
        xq[k] <= xq[k-1];
      end
      va <= 1'b1;
    end
  end

  // stage B: pairwise adder tree with a register after every level (no DSP cascade:
  // the cascade of 5 DSP48 in one 8 ns clock was the critical path)
  (* use_dsp = "no" *) logic signed [33:0] ai1 [0:7], aq1 [0:7];   // level 1: 15 -> 8
  (* use_dsp = "no" *) logic signed [34:0] ai2 [0:3], aq2 [0:3];   // level 2: 8 -> 4
  (* use_dsp = "no" *) logic signed [35:0] ai3 [0:1], aq3 [0:1];   // level 3: 4 -> 2
  logic vb1 = 1'b0, vb2 = 1'b0, vb3 = 1'b0;
  always_ff @(posedge clk) begin
    vb1 <= va; vb2 <= vb1; vb3 <= vb2;
    for (int k = 0; k < 7; k++) begin
      ai1[k] <= 34'(pi[2*k]) + 34'(pi[2*k+1]);
      aq1[k] <= 34'(pq[2*k]) + 34'(pq[2*k+1]);
    end
    ai1[7] <= 34'(pi[14]);
    aq1[7] <= 34'(pq[14]);
    for (int k = 0; k < 4; k++) begin
      ai2[k] <= 35'(ai1[2*k]) + 35'(ai1[2*k+1]);
      aq2[k] <= 35'(aq1[2*k]) + 35'(aq1[2*k+1]);
    end
    for (int k = 0; k < 2; k++) begin
      ai3[k] <= 36'(ai2[2*k]) + 36'(ai2[2*k+1]);
      aq3[k] <= 36'(aq2[2*k]) + 36'(aq2[2*k+1]);
    end
  end

  // stage C: final sum and scale
  (* use_dsp = "no" *) logic signed [36:0] fi, fq;
  logic vc = 1'b0;
  always_ff @(posedge clk) begin
    vc <= vb3;
    fi <= 37'(ai3[0]) + 37'(ai3[1]);
    fq <= 37'(aq3[0]) + 37'(aq3[1]);
    out_valid <= vc;
    i_out <= IN_W'(fi >>> 15);
    q_out <= IN_W'(fq >>> 15);
  end
endmodule
