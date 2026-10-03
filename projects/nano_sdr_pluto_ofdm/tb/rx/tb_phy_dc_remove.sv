// Self-checking TB: phy_dc_remove vs python/rx_blocks_ref.py::dc_remove (bit-exact). TAG 1: K=10, TAG 2: K=4 (generic K).
// Tests: nominal/boundary/random data, valid gaps, exact latency (output valid = input valid delayed by LATENCY), reset
// during processing and a clean full run afterwards.
module tb_phy_dc_remove #(parameter int TAG = 1, parameter int K = 10);
  localparam int LATENCY = 1, MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [16:0] stim [MAXN];
  logic [15:0] expd [MAXN];
  string fname;
  logic in_valid = 0; logic signed [15:0] in_data = 0;
  logic out_valid; logic signed [15:0] out_data;
  phy_dc_remove #(.K(K)) dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  bit checking = 0;
  logic [LATENCY:0] vpipe = '0;
  always @(posedge clk) vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst};
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; if (errors < 10) $display("latency/valid mismatch at output %0d", nout); end
    if (out_valid) begin
      if (out_data !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %h exp %h", nout, out_data, expd[nout]);
      end
      nout++;
    end
  end

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 'x; expd[i] = 'x; end
    $sformat(fname, "vec/dcr%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/dcr%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;

    repeat (4) @(posedge clk); #1; rst = 0;
    // reset during processing
    for (int i = 0; i < 40; i++) begin @(posedge clk); #1; in_valid = 1; in_data = 16'sd2000; end
    rst = 1; repeat (3) @(posedge clk); #1; rst = 0; in_valid = 0; repeat (LATENCY + 4) @(posedge clk);
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end

    checking = 1; nout = 0;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][16]; in_data = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0;
    repeat (LATENCY + 8) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_dc_remove TAG=%0d (%0d samples)", TAG, nout);
    else $display("TEST FAILED tb_phy_dc_remove TAG=%0d errors=%0d", TAG, errors);
    $finish;
  end
endmodule
