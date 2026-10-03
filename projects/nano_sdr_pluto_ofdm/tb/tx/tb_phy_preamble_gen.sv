// Self-checking TB: phy_preamble_gen kinds 0 (sync) and 1 (LTS) vs python/ofdm_ref.py::preamble (bit-exact).
// Tests: start requests with random idle gaps, kind latched at the handshake, first/last flags, exact latency
// (first output 2 cycles after the start handshake edge: start latch + output register), alternating kinds, reset mid-symbol, no output when idle.
module tb_phy_preamble_gen;
  localparam int N = 2048;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] exp0 [N];
  logic [31:0] exp1 [N];
  logic start_valid = 0, start_ready, start_kind = 0;
  logic out_valid, out_first, out_last; logic signed [15:0] out_re, out_im;
  phy_preamble_gen dut (.*);

  int errors = 0, nout = 0, cyc = 0, hs_cyc = -1, first_cyc = -1;
  bit checking = 0, cur_kind = 0;
  always @(posedge clk) cyc <= cyc + 1;

  always @(posedge clk) begin
    if (start_valid && start_ready && !rst) hs_cyc <= cyc;
    if (checking && !rst && out_valid) begin
      if (nout == 0) first_cyc = cyc;
      if ({out_re, out_im} !== (cur_kind ? exp1[nout] : exp0[nout])) begin
        errors++;
        if (errors < 10) $display("DATA mismatch kind %0d bin %0d got %04x/%04x", cur_kind, nout, out_re & 16'hFFFF, out_im & 16'hFFFF);
      end
      if (out_first !== (nout == 0) || out_last !== (nout == N - 1)) begin errors++; $display("flag mismatch at %0d", nout); end
      nout++;
    end
  end

  task automatic one(input bit kind);
    repeat ($urandom_range(0, 5)) @(posedge clk);
    @(posedge clk); #1; start_valid = 1; start_kind = kind; cur_kind = kind; nout = 0;
    do @(posedge clk); while (!start_ready);
    #1; start_valid = 0; start_kind = ~kind;      // kind must be latched at the handshake
    repeat (N + 10) @(posedge clk);
    if (nout !== N) begin errors++; $display("count %0d != %0d", nout, N); end
    if (first_cyc - hs_cyc !== 2) begin errors++; $display("latency: first output %0d cycles after handshake (exp 2)", first_cyc - hs_cyc); end
  endtask

  initial begin
    $readmemh("vec/pre0_exp.mem", exp0);
    $readmemh("vec/pre1_exp.mem", exp1);
    repeat (4) @(posedge clk); #1; rst = 0;
    checking = 1; repeat (30) @(posedge clk);
    if (nout !== 0) begin errors++; $display("output while idle"); end
    // reset mid-symbol
    checking = 0; cur_kind = 1; start_valid = 1; start_kind = 1; @(posedge clk); #1; start_valid = 0; repeat (500) @(posedge clk);
    #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    one(0); one(1); one(1); one(0);
    if (errors == 0) $display("TEST PASSED tb_phy_preamble_gen");
    else $display("TEST FAILED tb_phy_preamble_gen errors=%0d", errors);
    $finish;
  end
endmodule
