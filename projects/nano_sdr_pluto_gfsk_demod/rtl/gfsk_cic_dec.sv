// ***************************************************************************
// GFSK RX: CIC decimator, R = 8, N = 3, M = 1 (multiplier-free).
//   Gain R^N = 512, so the output is shifted right by 9.
//   Integrators wrap (modular arithmetic gives the exact comb output).
//   Comb section is pipelined: one subtractor per clock after each decimation event
//   (3 clocks; decimation events are >= 8 input samples apart).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_cic_dec #(
  parameter int IN_W = 16,
  parameter int R    = 8,
  parameter int W    = 32
) (
  input  logic                    clk,
  input  logic                    en_in,     // input strobe (fs)
  input  logic signed [IN_W-1:0]  din,
  output logic                    en_out,    // output strobe (fs / R)
  output logic signed [IN_W-1:0]  dout
);
  logic signed [W-1:0] i1 = '0, i2 = '0, i3 = '0;
  logic signed [W-1:0] c1 = '0, c2 = '0, c3 = '0;
  logic [$clog2(R)-1:0] cnt = '0;

  logic signed [W-1:0] cap = '0;                 // integrator 3 at the decimation instant
  logic                s1 = 1'b0, s2 = 1'b0, s3 = 1'b0;
  logic signed [W-1:0] r1 = '0, r2 = '0;
  logic signed [W-1:0] d1, d2, d3;

  always_comb begin
    d1 = cap - c1;
    d2 = r1 - c2;
    d3 = r2 - c3;
  end

  always_ff @(posedge clk) begin
    en_out <= 1'b0;
    if (en_in) begin
      i1 <= i1 + W'(din);
      i2 <= i2 + i1;
      i3 <= i3 + i2;
      if (cnt == R-1) begin
        cnt <= '0;
        cap <= i3;
      end else begin
        cnt <= cnt + 1'b1;
      end
    end

    // comb pipeline
    s1 <= 1'b0;                                  // (overridden below if a new event started)
    if (en_in && cnt == R-1) s1 <= 1'b1;
    s2 <= 1'b0;
    if (s1) begin
      c1 <= cap;
      r1 <= d1;
      s2 <= 1'b1;
    end
    s3 <= 1'b0;
    if (s2) begin
      c2 <= r1;
      r2 <= d2;
      s3 <= 1'b1;
    end
    if (s3) begin
      c3     <= r2;
      dout   <= IN_W'(d3 >>> 9);
      en_out <= 1'b1;
    end
  end
endmodule
