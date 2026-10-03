// Self-checking TB: phy_pilot_insert vs python/ofdm_ref.py::insert_pilots (bit-exact), valid gaps with garbage on idle
// cycles, exact latency (valid delayed by 1), first/last alignment, LFSR restart per symbol, reset mid-symbol.
module tb_phy_pilot_insert;
  localparam int N = 2048, MAXN = 8192, LATENCY = 1;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [35:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic in_valid = 0, in_first = 0, in_last = 0, in_pilot = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid, out_first, out_last; logic signed [15:0] out_re, out_im;
  phy_pilot_insert dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  bit checking = 0;
  logic vpipe = 0, fpipe = 0, lpipe = 0;
  always @(posedge clk) begin
    vpipe <= in_valid & ~rst; fpipe <= in_valid & in_first & ~rst; lpipe <= in_valid & in_last & ~rst;
  end
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe) begin errors++; $display("latency/valid mismatch"); end
    if (out_valid) begin
      if (out_first !== fpipe || out_last !== lpipe) begin errors++; $display("first/last mismatch at %0d", nout); end
      if ({out_re, out_im} !== expd[nout]) begin
        errors++;
        if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
      end
      nout++;
    end
  end

  task automatic play(input int count);
    for (int i = 0; i < count; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][35]; in_first = stim[i][34]; in_last = stim[i][33]; in_pilot = stim[i][32];
      in_re = stim[i][31:16]; in_im = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0; in_pilot = 0;
    repeat (4) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 36'bx; expd[i] = 32'bx; end
    $readmemh("vec/pil_in.mem", stim);
    $readmemh("vec/pil_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    // reset mid-symbol (pilot LFSR advanced) -> next run must still start from SEED
    play(900);
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    checking = 1; nout = 0;
    play(ns);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_pilot_insert (%0d samples)", nout);
    else $display("TEST FAILED tb_phy_pilot_insert errors=%0d", errors);
    $finish;
  end
endmodule
