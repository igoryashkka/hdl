// Self-checking TB: phy_equalizer vs python/rx_fixed_ref.py::equalize (bit-exact). The weight RAM is modelled in the TB
// (1-cycle synchronous read, contents = eqw_exp.mem produced by the golden chest()). Boundary inputs (+-full scale, 0),
// random data, valid gaps with garbage on idle cycles, exact latency (4), first/last flags, reset mid-frame.
module tb_phy_equalizer;
  localparam int NA = 1200, MAXN = 4096, LATENCY = 7;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [34:0] stim [MAXN];
  logic [31:0] expd [NA];
  logic [39:0] wmem [NA];
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic [10:0] rd_addr; logic [39:0] rd_data;
  logic out_valid, out_first, out_last; logic signed [15:0] out_re, out_im;
  phy_equalizer dut (.*);

  always @(posedge clk) rd_data <= wmem[rd_addr];    // external RAM model, 1 cycle read latency

  int errors = 0, nout = 0, ns = 0;
  bit checking = 0;
  logic [LATENCY:0] vpipe = '0, fpipe = '0, lpipe = '0;
  always @(posedge clk) begin
    vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst};
    fpipe <= {fpipe[LATENCY-1:0], in_valid & in_first & ~rst};
    lpipe <= {lpipe[LATENCY-1:0], in_valid & in_last & ~rst};
  end
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; if (errors < 10) $display("latency/valid mismatch"); end
    if (out_valid) begin
      if (out_first !== fpipe[LATENCY-1] || out_last !== lpipe[LATENCY-1]) begin errors++; $display("first/last mismatch at %0d", nout); end
      if ({out_re, out_im} !== expd[nout]) begin
        errors++; if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      nout++;
    end
  end

  task automatic play(input int count);
    for (int i = 0; i < count; i++) begin
      while ($urandom_range(0, 9) < 3) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
      @(posedge clk); #1;
      in_valid = stim[i][34]; in_first = stim[i][33]; in_last = stim[i][32]; in_re = stim[i][31:16]; in_im = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (LATENCY + 6) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 35'bx;
    $readmemh("vec/eq_in.mem", stim);
    $readmemh("vec/eqw_exp.mem", wmem);
    $readmemh("vec/eq_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    play(500);
    @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    checking = 1; nout = 0;
    play(ns);
    if (nout !== NA) begin errors++; $display("count %0d != %0d", nout, NA); end
    if (errors == 0) $display("TEST PASSED tb_phy_equalizer (%0d bins)", nout);
    else $display("TEST FAILED tb_phy_equalizer errors=%0d", errors);
    $finish;
  end
endmodule
