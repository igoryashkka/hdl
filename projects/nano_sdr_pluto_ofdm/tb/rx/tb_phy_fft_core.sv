// Self-checking TB: phy_fft_core vs python/fft_ref.py (bit-exact). Parameters (via generics): TAG selects the vector set
// (python/generate_vectors.py FFT_CFGS), N_LOG, MASK must match it.
// Tests: (1) continuous valid: first output exactly LATENCY cycles after first input, whole stream bit-exact;
//        (2) reset in the middle of a frame, then (3) random valid gaps (garbage on idle cycles), bit-exact.
module tb_phy_fft_core #(parameter int TAG = 1, parameter int N_LOG = 4, parameter int MASK = 15);
  localparam int N = 1 << N_LOG, MAXN = 32768, W = 18;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [35:0] stim [MAXN];
  logic [35:0] expd [MAXN];
  logic in_valid = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid; logic signed [W-1:0] out_re, out_im;
  phy_fft_core #(.N_LOG(N_LOG), .SHIFT_MASK(MASK)) dut (.clk, .rst, .in_valid, .in_re, .in_im, .out_valid, .out_re, .out_im);

  int errors = 0, nout = 0, ns = 0, ne = 0, cyc = 0, first_in = -1, first_out = -1;
  bit checking = 0;
  always @(posedge clk) cyc <= cyc + 1;

  always @(negedge clk) if (checking && out_valid) begin
    if (first_out < 0) first_out = cyc;
    if (nout < ne && {out_re, out_im} !== expd[nout]) begin
      errors++;
      if (errors < 10) $display("DATA mismatch #%0d got %05x/%05x exp %09x", nout, out_re & 18'h3FFFF, out_im & 18'h3FFFF, expd[nout]);
    end
    nout++;
  end

  string fname;
  task automatic run_vec(input bit gaps, input int stop_at);
    int n;
    if (gaps) $sformat(fname, "vec/fft%0d_g_in.mem", TAG); else $sformat(fname, "vec/fft%0d_c_in.mem", TAG);
    for (int i = 0; i < MAXN; i++) stim[i] = 36'bx;
    $readmemh(fname, stim);
    n = 0; while (^stim[n] !== 1'bx) n++;
    if (stop_at >= 0 && stop_at < n) n = stop_at + 1;
    for (int i = 0; i < n; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][32]; in_re = stim[i][31:16]; in_im = stim[i][15:0];
      if (stim[i][32] && first_in < 0) first_in = cyc;
    end
    if (stop_at < 0) begin
      @(posedge clk); #1; in_valid = 0;
      repeat (100) @(posedge clk);
    end
  endtask

  task automatic reset_dut();
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) expd[i] = 36'bx;
    $sformat(fname, "vec/fft%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);

    // (1) continuous
    checking = 1; first_in = -1; first_out = -1; nout = 0;
    run_vec(0, -1);
    // total outputs = frames*N + 1 (first sample of the flush frame leaves the pipe as well)
    if (nout !== ne + 1) begin errors++; $display("count %0d != %0d", nout, ne + 1); end
    // latency: output sample 0 is produced LATENCY cycles after input sample 0 (valid of in sampled at posedge, out checked at negedge)
    if (first_out - first_in !== dut.LATENCY) begin
      errors++; $display("LATENCY mismatch: measured %0d expected %0d", first_out - first_in, dut.LATENCY);
    end

    // (2) reset mid-frame; afterwards nothing must come out until a fresh stream is fed
    checking = 0;
    reset_dut();
    run_vec(0, N + N/2);
    reset_dut();
    in_valid = 0; checking = 1; nout = 0; repeat (3 * N) @(posedge clk);
    if (nout !== 0) begin errors++; $display("output after reset without input (%0d)", nout); end

    // (3) gaps
    first_in = -1; first_out = -1; nout = 0;
    run_vec(1, -1);
    if (nout !== ne + 1) begin errors++; $display("gap run count %0d != %0d", nout, ne + 1); end

    if (errors == 0) $display("TEST PASSED tb_phy_fft_core N=%0d MASK=%0h (%0d samples, latency %0d)", N, MASK, nout, dut.LATENCY);
    else $display("TEST FAILED tb_phy_fft_core N=%0d errors=%0d", N, errors);
    $finish;
  end
endmodule
