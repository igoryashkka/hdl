// Self-checking TB: phy_scrambler vs python/scrambler_ref.py. Tests: nominal+boundary+random frames,
// valid gaps (garbage on idle cycles), exact latency (valid delayed by LATENCY), reset during
// idle/processing, first/last alignment.
module tb_phy_scrambler;
  localparam int LATENCY = 1;
  localparam int NS = 2216, NE = 1508;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [11:0] stim [NS];
  logic [7:0]  expd [NE];
  logic in_valid = 0, in_first = 0, in_last = 0; logic [7:0] in_data = 0;
  logic out_valid, out_first, out_last; logic [7:0] out_data;
  phy_scrambler dut (.clk, .rst, .in_valid, .in_first, .in_last, .in_data, .out_valid, .out_first, .out_last, .out_data);

  int errors = 0, nout = 0, cyc = 0;
  logic [LATENCY:0] vpipe = '0;      // expected valid history
  logic [LATENCY:0] fpipe = '0, lpipe = '0;
  bit checking = 0;

  always @(posedge clk) begin
    cyc <= cyc + 1;
    vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst}; fpipe <= {fpipe[LATENCY-1:0], in_first & in_valid & ~rst};
    lpipe <= {lpipe[LATENCY-1:0], in_last & in_valid & ~rst};
  end
  // sample outputs just before the next edge, on negedge
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; $display("%0t LATENCY/valid mismatch cyc=%0d", $time, cyc); end
    if (out_valid) begin
      if (out_first !== fpipe[LATENCY-1] || out_last !== lpipe[LATENCY-1]) begin errors++; $display("first/last mismatch"); end
      if (nout < NE && out_data !== expd[nout]) begin errors++; $display("DATA mismatch #%0d got %02x exp %02x", nout, out_data, expd[nout]); end
      nout++;
    end
  end

  task automatic run_stim(input int n);
    for (int i = 0; i < n; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][8]; in_first = stim[i][9]; in_last = stim[i][10]; in_data = stim[i][7:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (5) @(posedge clk);
  endtask

  initial begin
    $readmemh("vec/scr_stim.mem", stim);
    $readmemh("vec/scr_exp.mem", expd);
    // reset while idle
    repeat (4) @(posedge clk); #1; rst = 0;
    // reset during processing: stream some data, assert reset, verify outputs go low
    @(posedge clk); #1; in_valid = 1; in_first = 1; in_data = 8'hA5;
    repeat (3) begin @(posedge clk); #1; in_first = 0; end
    rst = 1;
    @(posedge clk); #1; @(posedge clk); #1;
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end
    in_valid = 0; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    run_stim(NS);
    if (nout !== NE) begin errors++; $display("output count %0d != %0d", nout, NE); end
    if (errors == 0) $display("TEST PASSED tb_phy_scrambler (%0d bytes)", nout);
    else $display("TEST FAILED tb_phy_scrambler errors=%0d", errors);
    $finish;
  end
endmodule
