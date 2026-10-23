// Self-checking TB: phy_tx_weight vs python/bf_ref.py::apply_weight (bit-exact), vectors from generate_vectors_bf.py.
// 8 frames of 2048 bins with random gaps (garbage data on idle cycles): bypass, weights (amp/phase/tau incl. +-40 samples,
// full-scale input, phase/tau wrap), mute, amp = 0; per-frame load, bin_rst between frames except one (natural counter wrap).
// Checks: every output bin, exact latency (out_valid = in_valid delayed by 12), output count, reset during processing.
module tb_phy_tx_weight;
  localparam int LATENCY = 12, MAXS = 32768, MAXE = 20000;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [86:0] stim [MAXS];
  logic [31:0] expd [MAXE];
  logic bin_rst = 0, load = 0, in_valid = 0; logic [1:0] mode_i = 0; logic [15:0] amp_i = 0, phase_i = 0;
  logic signed [16:0] tau_i = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid; logic signed [15:0] out_re, out_im;
  phy_tx_weight dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  bit checking = 0;
  logic [LATENCY:0] vpipe = '0;
  always @(posedge clk) vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst & ~bin_rst};
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; if (errors < 10) $display("latency/valid mismatch at out #%0d", nout); end
    if (out_valid) begin
      if ({out_re, out_im} !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d (frame %0d bin %0d) got %04x/%04x exp %08x", nout, nout / 2048, nout % 2048,
                                           out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      nout++;
    end
  end

  initial begin
    for (int i = 0; i < MAXS; i++) stim[i] = 87'bx;
    for (int i = 0; i < MAXE; i++) expd[i] = 32'bx;
    $readmemh("vec/bf_w_stim.mem", stim); $readmemh("vec/bf_w_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    for (int i = 0; i < 30; i++) begin @(posedge clk); #1; in_valid = 1; in_re = 16'sd1000; in_im = -16'sd1000; end
    rst = 1; @(posedge clk); #1; @(posedge clk); #1;
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end
    in_valid = 0; rst = 0; repeat (20) @(posedge clk);
    checking = 1;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      {load, mode_i, amp_i, phase_i, tau_i, bin_rst, in_valid, in_re, in_im} = stim[i];
      if (load) begin in_valid = 0; end
    end
    @(posedge clk); #1; in_valid = 0; load = 0; bin_rst = 0;
    repeat (20) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_tx_weight (%0d bins, 8 frames)", nout);
    else $display("TEST FAILED tb_phy_tx_weight errors=%0d", errors);
    $finish;
  end
endmodule
