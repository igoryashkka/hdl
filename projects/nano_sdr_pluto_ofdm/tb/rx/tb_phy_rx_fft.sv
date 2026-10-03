// Self-checking TB: phy_rx_fft (FFT + saturation + bit-reverse reorder) vs python/rx_fixed_ref.py::rx_fft, bit-exact
// natural-order frames. 3 frames (first = full-scale constant) separated by idle time (like the CP gap), N-1 flush zeros,
// random output backpressure with stability check, exact frame count, flags, frame_written pulses, then core_rst and a
// second identical pass (checks the soft reset realigns the SDF stages), overflow must stay 0.
module tb_phy_rx_fft #(parameter int TAG = 1, parameter int N_LOG = 4, parameter int MASK = 15);
  localparam int N = 1 << N_LOG, NF = 3, MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  string fname;
  logic core_rst = 0, in_valid = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic frame_written, overflow, out_valid, out_ready = 0, out_first, out_last, frame_done; logic signed [15:0] out_re, out_im;
  phy_rx_fft #(.N_LOG(N_LOG), .SHIFT_MASK(MASK)) dut (.*);

  int errors = 0, nout = 0, nfw = 0;
  bit checking = 0;
  logic [31:0] held; bit has_held = 0;

  always @(posedge clk) if (checking && !rst) begin
    if (has_held && !(out_valid && {out_re, out_im} === held)) begin errors++; $display("output changed/dropped while stalled"); end
    has_held <= out_valid && !out_ready; held <= {out_re, out_im};
    if (frame_written) nfw++;
    if (out_valid && out_ready) begin
      if (nout < NF * N && {out_re, out_im} !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      if (out_first !== (nout % N == 0) || out_last !== (nout % N == N - 1)) begin errors++; $display("flag mismatch at %0d", nout); end
      nout++;
    end
  end
  always @(posedge clk) out_ready <= ($urandom_range(0, 9) < 6);

  task automatic pass();
    for (int f = 0; f < NF; f++) begin
      for (int i = 0; i < N; i++) begin
        while ($urandom_range(0, 9) < 1) begin @(posedge clk); #1; in_valid = 0; end      // random valid gap
        @(posedge clk); #1; in_valid = 1; in_re = stim[f * N + i][31:16]; in_im = stim[f * N + i][15:0];
      end
      @(posedge clk); #1; in_valid = 0; repeat (3 * N) @(posedge clk);          // CP gap / idle
    end
    for (int i = 0; i < N - 1; i++) begin @(posedge clk); #1; in_valid = 1; in_re = 0; in_im = 0; end    // flush
    @(posedge clk); #1; in_valid = 0;
    repeat (4 * N + 100) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 32'bx; expd[i] = 32'bx; end
    $sformat(fname, "vec/rxf%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/rxf%0d_exp.mem", TAG); $readmemh(fname, expd);
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    checking = 1;
    pass();
    if (nout !== NF * N) begin errors++; $display("pass 1: count %0d != %0d", nout, NF * N); end
    if (nfw !== NF) begin errors++; $display("pass 1: frame_written %0d != %0d", nfw, NF); end
    // soft reset, second pass must be identical
    @(posedge clk); #1; core_rst = 1; @(posedge clk); #1; core_rst = 0; repeat (3) @(posedge clk);
    nout = 0; nfw = 0;
    pass();
    if (nout !== NF * N) begin errors++; $display("pass 2: count %0d != %0d", nout, NF * N); end
    if (nfw !== NF) begin errors++; $display("pass 2: frame_written %0d != %0d", nfw, NF); end
    if (overflow) begin errors++; $display("overflow"); end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_fft TAG=%0d N=%0d (2 passes x %0d samples)", TAG, N, NF * N);
    else $display("TEST FAILED tb_phy_rx_fft TAG=%0d errors=%0d", TAG, errors);
    $finish;
  end
endmodule
