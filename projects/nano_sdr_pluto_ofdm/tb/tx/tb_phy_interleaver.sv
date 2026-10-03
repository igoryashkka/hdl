// Self-checking TB: phy_interleaver (interleave and deinterleave) vs python/interleaver_ref.py, bit-exact.
// Tests: 3 blocks, random input valid gaps, random output backpressure (data must be stable while stalled),
// first/last flags, no loss/duplication, reset in the middle of a block (then a clean full run), exact word count.
module tb_phy_interleaver #(
  parameter int TAG = 1, parameter int DEINT = 0, parameter int WORD_W = 4, parameter int ROT_UNIT = 1,
  parameter int ROWS = 55, parameter int COLS = 20
);
  localparam int NSYM = ROWS * COLS, MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [31:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic in_valid = 0; logic [WORD_W-1:0] in_data = 0;
  logic in_ready, out_valid, out_ready = 0, out_first, out_last; logic [WORD_W-1:0] out_data;
  phy_interleaver #(.WORD_W(WORD_W), .ROT_UNIT(ROT_UNIT), .ROWS(ROWS), .COLS(COLS), .DEINT(DEINT)) dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  string fname;
  bit checking = 0;
  logic [WORD_W-1:0] held_data; bit held = 0;

  // monitor (samples pre-edge values at posedge)
  always @(posedge clk) if (checking && !rst) begin
    if (held && !(out_valid && out_data === held_data)) begin errors++; $display("output changed/dropped while stalled"); end
    held <= out_valid && !out_ready; held_data <= out_data;
    if (out_valid && out_ready) begin
      if (nout < ne && out_data !== expd[nout][WORD_W-1:0]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %h exp %h", nout, out_data, expd[nout][WORD_W-1:0]);
      end
      if (out_first !== (nout % NSYM == 0)) begin errors++; $display("first flag wrong at %0d", nout); end
      if (out_last  !== (nout % NSYM == NSYM - 1)) begin errors++; $display("last flag wrong at %0d", nout); end
      nout++;
    end
  end
  always @(posedge clk) out_ready <= ($urandom_range(0, 9) < 6);   // 60% ready, changes every cycle

  task automatic drive(input int count);
    int i; bit acc;
    i = 0;
    while (i < count) begin
      @(posedge clk); acc = in_valid && in_ready; #1;   // handshake decided by pre-edge values
      if (acc) i++;
      if (in_valid && !acc) begin
        // hold the current word until accepted
      end else if (i < count && $urandom_range(0, 9) < 7) begin in_valid = 1; in_data = stim[i][WORD_W-1:0]; end
      else in_valid = 0;
    end
    @(posedge clk); #1; in_valid = 0;
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 32'bx; expd[i] = 32'bx; end
    $sformat(fname, "vec/itl%0d_in.mem", TAG);  $readmemh(fname, stim);
    $sformat(fname, "vec/itl%0d_exp.mem", TAG); $readmemh(fname, expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;

    // reset in the middle of a block
    checking = 0;
    drive(NSYM / 2);
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    if (out_valid !== 0) begin errors++; $display("out_valid after reset"); end

    // full run
    checking = 1; nout = 0;
    drive(ns);
    repeat (6 * NSYM) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_interleaver TAG=%0d DEINT=%0d W=%0d (%0d words)", TAG, DEINT, WORD_W, nout);
    else $display("TEST FAILED tb_phy_interleaver TAG=%0d errors=%0d", TAG, errors);
    $finish;
  end
endmodule
