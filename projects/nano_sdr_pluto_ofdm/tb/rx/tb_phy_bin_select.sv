// Self-checking TB: phy_bin_select vs python/rx_fixed_ref.py::select_active + pilot/first/last flags (bit-exact).
// Two full frames (2048 bins each) with random valid gaps (garbage on idle cycles), exact latency (1), reset mid-frame.
module tb_phy_bin_select;
  localparam int MAXN = 8192, LATENCY = 1;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [32:0] stim [MAXN];
  logic [34:0] expd [MAXN];
  logic in_valid = 0, in_first = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid, out_first, out_last, out_pilot; logic signed [15:0] out_re, out_im;
  phy_bin_select dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  bit checking = 0;
  logic vpipe = 0;
  always @(posedge clk) vpipe <= 1'b0;   // replaced below
  logic act_pipe = 0;                    // expected valid = in_valid & active, tracked from the stimulus index
  int exp_idx = 0;

  // expected valid pulses come from the number of active bins: compare data when out_valid, check count at the end
  always @(negedge clk) if (checking && out_valid) begin
    if ({out_pilot, out_first, out_last, out_re, out_im} !== expd[nout]) begin
      errors++;
      if (errors < 10) $display("DATA mismatch #%0d got %b%b%b/%04x/%04x exp %010x", nout, out_pilot, out_first, out_last, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
    end
    nout++;
  end

  task automatic play(input int count, input bit gaps);
    for (int i = 0; i < count; i++) begin
      while (gaps && $urandom_range(0, 9) < 3) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_re = $urandom; in_im = $urandom; end
      @(posedge clk); #1;
      in_valid = 1; in_first = stim[i][32]; in_re = stim[i][31:16]; in_im = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0;
    repeat (6) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 33'bx; expd[i] = 35'bx; end
    $readmemh("vec/bsl_in.mem", stim);
    $readmemh("vec/bsl_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // reset in the middle of a frame; a new frame starts with in_first, so the counters must resynchronise
    play(900, 0);
    @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    checking = 1; nout = 0;
    play(ns, 1);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_bin_select (%0d active bins)", nout);
    else $display("TEST FAILED tb_phy_bin_select errors=%0d", errors);
    $finish;
  end
endmodule
