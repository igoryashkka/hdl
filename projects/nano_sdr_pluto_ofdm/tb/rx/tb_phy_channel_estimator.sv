// Self-checking TB: phy_channel_estimator vs python/rx_fixed_ref.py::chest (bit-exact weights mantissa/exponent in the RAM).
// One LTS frame of 1200 active bins (boundary: zeros, +-full scale, +-1, small, random) with valid gaps (garbage on idle
// cycles), `done` exactly once, RAM read port (1-cycle latency), reset in the middle of a frame then a clean frame, and a
// second frame back to back (LFSR/counters restart at in_first).
module tb_phy_channel_estimator;
  localparam int NA = 1200, MAXN = 4096;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [34:0] stim [MAXN];
  logic [39:0] expd [NA];
  logic [11:0] expl [NA];
  logic [10:0] eng_ra = 0; logic [39:0] eng_rw; logic signed [11:0] eng_rlg; logic eng_we = 0; logic [10:0] eng_wa = 0; logic [39:0] eng_wd = 0;
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic done, rd_en = 0; logic [10:0] rd_addr = 0; logic [39:0] rd_data;
  phy_channel_estimator dut (.*);

  int errors = 0, ns = 0, ndone = 0;
  bit checking = 0;
  always @(posedge clk) if (checking && done) ndone++;

  task automatic play(input int count);
    for (int i = 0; i < count; i++) begin
      while ($urandom_range(0, 9) < 3) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
      @(posedge clk); #1;
      in_valid = stim[i][34]; in_first = stim[i][33]; in_last = stim[i][32]; in_re = stim[i][31:16]; in_im = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (40) @(posedge clk);
  endtask

  task automatic check_ram();
    for (int s = 0; s < NA; s++) begin
      @(posedge clk); #1; rd_en = 1; rd_addr = s;
      @(posedge clk); #1; rd_en = 0;
      if (rd_data !== expd[s]) begin
        errors++; if (errors < 10) $display("RAM mismatch s=%0d got %010x exp %010x", s, rd_data, expd[s]);
      end
      eng_ra = s; @(posedge clk); #1;
      if (eng_rw !== expd[s]) begin errors++; if (errors < 10) $display("mirror RAM mismatch s=%0d got %010x exp %010x", s, eng_rw, expd[s]); end
      if ({eng_rlg} !== expl[s]) begin errors++; if (errors < 10) $display("lg mismatch s=%0d got %0d exp %0d", s, eng_rlg, $signed(expl[s])); end
    end
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 35'bx;
    $readmemh("vec/cest_in.mem", stim);
    $readmemh("vec/cest_exp.mem", expd);
    $readmemh("vec/cest_lg.mem", expl);
    while (^stim[ns] !== 1'bx) ns++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // reset in the middle of a frame
    play(400);
    @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // frame 1
    checking = 1; ndone = 0;
    play(ns);
    if (ndone !== 1) begin errors++; $display("done pulses %0d (exp 1)", ndone); end
    check_ram();
    // frame 2 (RAM overwritten with identical data -> restart of the sign LFSR is exercised)
    ndone = 0;
    play(ns);
    if (ndone !== 1) begin errors++; $display("done pulses %0d (exp 1) in frame 2", ndone); end
    check_ram();
    // engine write port: rewrite one weight word, visible on both read ports
    @(posedge clk); #1; eng_we = 1; eng_wa = 11'd777; eng_wd = 40'hA5_1234_5678; @(posedge clk); #1; eng_we = 0;
    @(posedge clk); #1; rd_en = 1; rd_addr = 11'd777; eng_ra = 11'd777; @(posedge clk); #1; rd_en = 0;
    @(posedge clk); #1;
    if (rd_data !== 40'hA5_1234_5678 || eng_rw !== 40'hA5_1234_5678) begin errors++; $display("engine write failed %010x %010x", rd_data, eng_rw); end
    if (errors == 0) $display("TEST PASSED tb_phy_channel_estimator (%0d bins x 2)", NA);
    else $display("TEST FAILED tb_phy_channel_estimator errors=%0d", errors);
    $finish;
  end
endmodule
