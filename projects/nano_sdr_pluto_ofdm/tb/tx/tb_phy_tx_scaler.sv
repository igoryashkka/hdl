// Self-checking TB: phy_tx_scaler vs python/tx_ref.py::tx_scale (bit-exact). TAG selects gain (python SCL_GAINS) via GAIN.
// Tests: boundary (+-full scale, 0, +-1), random, gain 0 / 1.0 / 0.5 / ~4.0 (saturation), valid gaps with garbage on idle
// cycles, exact latency (valid delayed by 2), reset during processing.
module tb_phy_tx_scaler #(parameter int TAG = 1, parameter int GAIN = 16384);
  localparam int LATENCY = 2, MAXN = 4096;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [32:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic in_valid = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid; logic signed [15:0] out_re, out_im;
  logic [15:0] gain = GAIN;
  phy_tx_scaler dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  string fname;
  bit checking = 0;
  logic [LATENCY:0] vpipe = '0;
  always @(posedge clk) vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst};
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; $display("latency/valid mismatch"); end
    if (out_valid) begin
      if ({out_re, out_im} !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      nout++;
    end
  end

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 33'bx; expd[i] = 32'bx; end
    $sformat(fname, "vec/scl%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/scl%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    // reset during processing
    for (int i = 0; i < 20; i++) begin @(posedge clk); #1; in_valid = 1; in_re = 16'sd1000; in_im = -16'sd1000; end
    rst = 1; @(posedge clk); #1; @(posedge clk); #1; @(posedge clk); #1;
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end
    in_valid = 0; rst = 0; repeat (4) @(posedge clk);
    checking = 1;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][32]; in_re = stim[i][31:16]; in_im = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0;
    repeat (6) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_tx_scaler GAIN=%0d (%0d samples)", GAIN, nout);
    else $display("TEST FAILED tb_phy_tx_scaler GAIN=%0d errors=%0d", GAIN, errors);
    $finish;
  end
endmodule
