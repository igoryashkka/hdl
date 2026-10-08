// Self-checking TB: phy_mmse_post vs python/phy2_fixed_ref.py::post_engine. Two runs on the same weight memory model:
// MMSE (weights rewritten + parameters) and ZF (weights untouched + parameters); the estimator's memory ports are modelled with
// 1-cycle synchronous reads. Start order of chest_done / nu_valid is varied; `ready` must rise only after both and drop on clr.
module tb_phy_mmse_post;
  localparam int NA = 1200, ND = 1100;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [39:0] w0 [NA], wm [NA], expw [NA];
  logic [11:0] lg [NA];
  logic [12:0] nus [2];
  logic [28:0] expp1 [ND], expp0 [ND];
  logic [39:0] tmp40 [NA]; logic [31:0] tmpp [ND];
  logic clr = 0, cfg_mmse = 1, chest_done = 0, nu_valid = 0; logic signed [12:0] lg_nu = 0;
  logic [10:0] eng_ra, eng_wa; logic [39:0] eng_rw, eng_wd; logic signed [11:0] eng_rlg; logic eng_we;
  logic [10:0] prm_ra = 0; logic [28:0] prm_rd; logic ready, busy;
  phy_mmse_post dut (.*);
  always_ff @(posedge clk) begin
    eng_rw <= wm[eng_ra]; eng_rlg <= lg[eng_ra];
    if (eng_we) wm[eng_wa] <= eng_wd;
  end

  int errors = 0;
  task automatic run(input int mode, input bit nu_first);
    @(posedge clk); #1; clr = 1; cfg_mmse = mode; @(posedge clk); #1; clr = 0;
    for (int i = 0; i < NA; i++) wm[i] = w0[i];
    repeat (3) @(posedge clk);
    if (ready) begin errors++; $display("ready after clr"); end
    if (nu_first) begin @(posedge clk); #1; nu_valid = 1; lg_nu = $signed(nus[mode ? 0 : 1]); @(posedge clk); #1; nu_valid = 0; repeat (20) @(posedge clk); if (ready || busy) begin errors++; $display("started before chest_done"); end end
    @(posedge clk); #1; chest_done = 1; @(posedge clk); #1; chest_done = 0;
    if (!nu_first) begin repeat (7) @(posedge clk); #1; nu_valid = 1; lg_nu = $signed(nus[mode ? 0 : 1]); @(posedge clk); #1; nu_valid = 0; end
    repeat (3000) begin @(posedge clk); if (ready) break; end
    repeat (5) @(posedge clk);
    if (!ready) begin errors++; $display("never ready (mode %0d)", mode); end
    for (int i = 0; i < NA; i++) begin
      logic [39:0] e;
      e = mode ? expw[i] : w0[i];
      if (wm[i] !== e) begin errors++; if (errors < 8) $display("mode %0d weight %0d got %010x exp %010x", mode, i, wm[i], e); end
    end
    for (int j = 0; j < ND; j++) begin
      @(posedge clk); #1; prm_ra = j; @(posedge clk); #1;
      if (prm_rd !== (mode ? expp1[j] : expp0[j])) begin errors++; if (errors < 8) $display("mode %0d param %0d got %08x exp %08x", mode, j, prm_rd, mode ? expp1[j] : expp0[j]); end
    end
  endtask

  initial begin
    $readmemh("vec/eng_w.mem", w0);
    $readmemh("vec/eng_lg.mem", lg);
    $readmemh("vec/eng_nu.mem", nus);
    $readmemh("vec/eng_exp_w.mem", expw);
    $readmemh("vec/eng_exp_p1.mem", tmpp); for (int j = 0; j < ND; j++) expp1[j] = tmpp[j][28:0];
    $readmemh("vec/eng_exp_p0.mem", tmpp); for (int j = 0; j < ND; j++) expp0[j] = tmpp[j][28:0];
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    run(1, 0);
    run(0, 1);
    run(1, 1);
    if (errors == 0) $display("TEST PASSED tb_phy_mmse_post (MMSE / ZF runs bit-exact)");
    else $display("TEST FAILED tb_phy_mmse_post errors=%0d", errors);
    $finish;
  end
endmodule
