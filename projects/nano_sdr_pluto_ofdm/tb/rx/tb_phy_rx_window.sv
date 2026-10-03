// Self-checking TB: phy_rx_window. The sample value encodes its stream index, so the expected pass set is computed here:
// windows k = 0..NWIN-1 pass indices W0 + k*SYM .. +N-1; first/last/win flags; N-1 zero flush samples then done;
// the flush zeros are paced by in_valid; late arm (w0 in the past) ignored with `late`; arm while busy ignored; valid gaps; exact latency (1); reset mid-window.
// Generics: N, SYM (small values run fast; 2048/2192 is the real geometry).
module tb_phy_rx_window #(parameter int N = 16, parameter int SYM = 21, parameter int NWIN = 3);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic arm_valid = 0; logic [31:0] arm_w0 = 0; logic [7:0] arm_nwin = 0;
  logic in_valid = 0; logic signed [15:0] in_i = 0, in_q = 0;
  logic out_valid, out_first, out_last, busy, late, done; logic signed [15:0] out_i, out_q; logic [7:0] out_win;
  phy_rx_window #(.N(N), .SYM(SYM)) dut (.*);

  int errors = 0, idx = 0;          // idx = index of the next sample the stimulus will present
  int exp_next, w0, nout, nflush, ndone, nlate;
  int nw_cur = NWIN;
  bit checking = 0;
  logic vprev = 0; int iprev = 0;

  function automatic logic signed [15:0] enc_i(input int k); return 16'(k & 16'h7FFF); endfunction
  function automatic logic signed [15:0] enc_q(input int k); return 16'(-(k & 16'h7FFF) - 1); endfunction

  // output checker (outputs appear 1 clock after the input they correspond to)
  always @(posedge clk) begin
    if (checking && !rst) begin
      if (done) ndone++;
      if (late) nlate++;
      if (out_valid) begin
        if (out_i === 16'sd0 && out_q === 16'sd0 && nout >= nw_cur * N) begin
          nflush++;
        end else begin
          int k, p;
          k = nout / N; p = nout % N;
          if (out_i !== enc_i(w0 + k * SYM + p) || out_q !== enc_q(w0 + k * SYM + p)) begin
            errors++; if (errors < 4) $display("DATA mismatch window %0d pos %0d got %0d/%0d exp %0d st=%0d n=%0d nwin=%0d win=%0d wcnt=%0d next=%0d t=%0t", k, p, out_i, out_q, w0 + k * SYM + p, dut.st, dut.n, dut.nwin, dut.win, dut.wcnt, dut.next_start, $time);
          end
          if (out_first !== (p == 0) || out_last !== (p == N - 1) || out_win !== 8'(k)) begin
            errors++; if (errors < 10) $display("flag mismatch window %0d pos %0d", k, p);
          end
          nout++;
        end
      end
    end
  end

  task automatic feed(input int count, input bit gaps);
    @(posedge clk); #1;
    for (int i = 0; i < count; i++) begin
      while (gaps && $urandom_range(0, 9) < 3) begin in_valid = 0; in_i = 16'h1234; @(posedge clk); #1; end
      in_valid = 1; in_i = enc_i(idx); in_q = enc_q(idx); idx++;
      @(posedge clk); #1;
    end
    in_valid = 0;
  endtask

  task automatic arm(input int w, input int nwin);
    @(posedge clk); #1; arm_valid = 1; arm_w0 = w; arm_nwin = nwin; @(posedge clk); #1; arm_valid = 0;
  endtask

  initial begin
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // ---- scenario 1: normal frame, arm in the future
    feed(50, 1);
    w0 = idx + 30;
    checking = 1; nout = 0; nflush = 0; ndone = 0; nlate = 0;
    arm(w0, NWIN);
    arm(w0 + 1000, 5);                                  // arm while busy: ignored
    feed(30 + NWIN * SYM + N + 20, 1);
    repeat (N + 20) @(posedge clk);
    if (nout !== NWIN * N) begin errors++; $display("passed %0d != %0d", nout, NWIN * N); end
    if (nflush !== N - 1) begin errors++; $display("flush samples %0d != %0d", nflush, N - 1); end
    if (ndone !== 1) begin errors++; $display("done pulses %0d", ndone); end
    if (busy) begin errors++; $display("busy after done"); end
    // ---- scenario 2: late arm
    nlate = 0; nout = 0;
    arm(idx - 5, 2);
    feed(10, 0);
    repeat (6) @(posedge clk);
    if (nlate !== 1) begin errors++; $display("late pulses %0d (exp 1)", nlate); end
    if (nout !== 0) begin errors++; $display("output after late arm"); end
    // ---- scenario 3: reset in the middle of a window, then a clean frame
    checking = 0;
    w0 = idx + 5; arm(w0, NWIN); feed(5 + N / 2, 0);
    @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; idx = 0; repeat (2) @(posedge clk);
    if (busy) begin errors++; $display("busy after reset"); end
    feed(20, 0);
    w0 = idx + 10;
    checking = 1; nout = 0; nflush = 0; ndone = 0; nw_cur = 2;
    arm(w0, 2);
    feed(10 + 2 * SYM + N + 5, 0);
    repeat (N + 20) @(posedge clk);
    if (nout !== 2 * N || nflush !== N - 1 || ndone !== 1) begin errors++; $display("post-reset frame: nout=%0d nflush=%0d ndone=%0d", nout, nflush, ndone); end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_window N=%0d SYM=%0d", N, SYM);
    else $display("TEST FAILED tb_phy_rx_window errors=%0d", errors);
    $finish;
  end
endmodule
