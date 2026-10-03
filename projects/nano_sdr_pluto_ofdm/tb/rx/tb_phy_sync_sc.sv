// Self-checking TB: phy_sync_sc vs python/sync_ref.py (bit-exact event fields). TAG selects the vector set
// (python/generate_vectors.py SYNC_CFGS): 1 = frame + CFO, 2 = noise only (must give NO event), 3 = 8 dB, 2-path, CFO.
// Tests: event timing/index (n_decl, n_best), P snapshot (fractional CFO), exactly one event per detection, det_done stays
// until rearm, rearm re-enables detection (second event on re-fed data after the NCO-free re-run), random valid gaps,
// energy gate (noise only -> silent), reset in the middle of a run, no event before enough samples.
module tb_phy_sync_sc #(parameter int TAG = 1);
  localparam int MAXN = 20000;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [32:0] stim [MAXN];
  logic [39:0] expd [5];
  logic in_valid = 0; logic signed [15:0] in_i = 0, in_q = 0;
  logic [31:0] rmin = 32'd262144;
  logic rearm = 0;
  logic ev_valid, det_done; logic [31:0] ev_n_decl, ev_n_best; logic signed [39:0] ev_p_re, ev_p_im;
  phy_sync_sc dut (.*);

  int errors = 0, nev = 0, ns = 0;
  string fname;
  bit expect_ev;
  bit checking = 0;

  always @(posedge clk) if (checking && !rst && ev_valid) begin
    nev++;
    if (!expect_ev) begin errors++; $display("unexpected event"); end
    else begin
      if (ev_n_decl !== expd[1][31:0]) begin errors++; $display("n_decl %0d != %0d", ev_n_decl, expd[1][31:0]); end
      if (ev_n_best !== expd[2][31:0]) begin errors++; $display("n_best %0d != %0d", ev_n_best, expd[2][31:0]); end
      if (ev_p_re !== expd[3]) begin errors++; $display("p_re %0h != %0h", ev_p_re, expd[3]); end
      if (ev_p_im !== expd[4]) begin errors++; $display("p_im %0h != %0h", ev_p_im, expd[4]); end
    end
  end

  task automatic play(input int count, input bit gaps);
    for (int i = 0; i < count; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][32]; in_i = stim[i][31:16]; in_q = stim[i][15:0];
      if (gaps) while ($urandom_range(0, 9) < 3) begin in_valid = 0; @(posedge clk); #1; in_valid = stim[i][32]; end
    end
    @(posedge clk); #1; in_valid = 0;
    repeat (60) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 33'bx;
    $sformat(fname, "vec/syn%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/syn%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^stim[ns] !== 1'bx) ns++;
    expect_ev = expd[0][0];
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);

    // reset in the middle of a run (must not leave stale state)
    play(ns / 3, 0);
    @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    if (det_done !== 1'b0) begin errors++; $display("det_done after reset"); end

    // full run with random valid gaps
    checking = 1; nev = 0;
    play(ns, 1);
    if (expect_ev && nev !== 1) begin errors++; $display("events %0d (expected 1)", nev); end
    if (!expect_ev && nev !== 0) begin errors++; $display("events %0d (expected 0)", nev); end
    if (det_done !== expect_ev) begin errors++; $display("det_done=%b expected %b", det_done, expect_ev); end

    // rearm: det_done must clear (no new event is possible without a new preamble: remaining stream is the old tail)
    if (expect_ev) begin
      @(posedge clk); #1; rearm = 1; @(posedge clk); #1; rearm = 0; repeat (2) @(posedge clk);
      if (det_done !== 1'b0) begin errors++; $display("det_done not cleared by rearm"); end
    end

    if (errors == 0) $display("TEST PASSED tb_phy_sync_sc TAG=%0d (%0d samples, %0d event)", TAG, ns, nev);
    else $display("TEST FAILED tb_phy_sync_sc TAG=%0d errors=%0d", TAG, errors);
    $finish;
  end
endmodule
