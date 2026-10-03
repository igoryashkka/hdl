// Self-checking TB: phy_cp_insert (bit-reverse reorder + cyclic prefix) vs python/tx_ref.py::cp_insert (bit-exact).
// Tests: several frames written back-to-back in bit-reversed order with valid gaps (a new frame only starts while
// frame_ok=1, as the TX controller does), random read backpressure (data stable while stalled), first/last flags per
// symbol (N+CP samples), no loss/duplication, ping-pong operation (write of frame k+1 overlaps read of frame k),
// frame_written / sym_done pulse counts, overflow stays 0, reset mid-frame.
module tb_phy_cp_insert #(parameter int TAG = 1, parameter int N_LOG = 4, parameter int CP = 4, parameter int NB = 3);
  localparam int N = 1 << N_LOG, SYM = N + CP, MAXN = 16384;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic in_valid = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic frame_ok, frame_written, sym_done, overflow;
  logic out_valid, out_ready = 0, out_first, out_last; logic signed [15:0] out_re, out_im;
  phy_cp_insert #(.N_LOG(N_LOG), .CP(CP), .NB(NB)) dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0, nfw = 0, nsd = 0;
  string fname;
  bit checking = 0;
  logic [31:0] held; bit has_held = 0;

  always @(posedge clk) if (checking && !rst) begin
    if (has_held && !(out_valid && {out_re, out_im} === held)) begin errors++; $display("output changed/dropped while stalled"); end
    has_held <= out_valid && !out_ready; held <= {out_re, out_im};
    if (frame_written) nfw++;
    if (sym_done) nsd++;
    if (out_valid && out_ready) begin
      if ({out_re, out_im} !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      if (out_first !== (nout % SYM == 0)) begin errors++; $display("first flag wrong at %0d", nout); end
      if (out_last  !== (nout % SYM == SYM - 1)) begin errors++; $display("last flag wrong at %0d", nout); end
      nout++;
    end
  end
  always @(posedge clk) out_ready <= ($urandom_range(0, 9) < 5);

  task automatic write_frames(input int nframes);
    for (int f = 0; f < nframes; f++) begin
      // credit: wait for a free bank before starting a frame
      while (!frame_ok) begin @(posedge clk); #1; end
      for (int i = 0; i < N; i++) begin
        @(posedge clk); #1;
        while ($urandom_range(0, 9) < 2) begin in_valid = 0; in_re = $urandom; in_im = $urandom; @(posedge clk); #1; end
        in_valid = 1; in_re = stim[f * N + i][31:16]; in_im = stim[f * N + i][15:0];
      end
      @(posedge clk); #1; in_valid = 0;
    end
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 32'bx; expd[i] = 32'bx; end
    $sformat(fname, "vec/cpi%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/cpi%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    // reset in the middle of a frame
    for (int i = 0; i < N / 2; i++) begin @(posedge clk); #1; in_valid = 1; in_re = i; in_im = i; end
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    if (out_valid !== 0) begin errors++; $display("out_valid after reset"); end
    checking = 1; nout = 0;
    write_frames(ns / N);
    repeat (4 * SYM + 50) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (nfw !== ns / N || nsd !== ns / N) begin errors++; $display("pulse counts frame_written=%0d sym_done=%0d exp %0d", nfw, nsd, ns / N); end
    if (overflow) begin errors++; $display("overflow flagged"); end
    if (errors == 0) $display("TEST PASSED tb_phy_cp_insert N=%0d CP=%0d (%0d samples)", N, CP, nout);
    else $display("TEST FAILED tb_phy_cp_insert N=%0d errors=%0d", N, errors);
    $finish;
  end
endmodule
