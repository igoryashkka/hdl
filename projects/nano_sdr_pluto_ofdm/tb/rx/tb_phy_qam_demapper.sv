// Self-checking TB: phy_qam_demapper vs python/qam_ref.py (bit-exact LLRs), per ORDER (GENERIC=ORDER=n).
// Inputs: full-scale boundary points, noisy constellation, valid gaps with garbage, exact latency, reset.
module tb_phy_qam_demapper #(parameter int ORDER = 16);
  localparam int LATENCY = 2, BPS = $clog2(ORDER), MAXN = 4096;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [34:0]        stim [MAXN];
  logic [8*BPS-1:0]   expd [MAXN];
  logic in_valid = 0, in_last = 0; logic signed [15:0] in_i = 0, in_q = 0;
  logic out_valid, out_last; logic signed [7:0] out_llr [BPS];
  phy_qam_demapper #(.ORDER(ORDER)) dut (.clk, .rst, .in_valid, .in_last, .in_i, .in_q, .out_valid, .out_last, .out_llr);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  logic [LATENCY:0] vpipe = '0, lpipe = '0;
  bit checking = 0;
  logic [8*BPS-1:0] got;
  always @(posedge clk) begin
    vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst};
    lpipe <= {lpipe[LATENCY-1:0], in_valid & in_last & ~rst};
  end
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; $display("latency/valid mismatch"); end
    if (out_valid) begin
      for (int b = 0; b < BPS; b++) got[8*(BPS-1-b) +: 8] = out_llr[b];
      if (out_last !== lpipe[LATENCY-1]) begin errors++; $display("last mismatch"); end
      if (got !== expd[nout]) begin errors++; $display("LLR mismatch #%0d got %h exp %h", nout, got, expd[nout]); end
      nout++;
    end
  end

  initial begin
    string f;
    $sformat(f, "vec/dem%0d_stim.mem", ORDER); $readmemh(f, stim);
    $sformat(f, "vec/dem%0d_exp.mem", ORDER);  $readmemh(f, expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    @(posedge clk); #1; in_valid = 1; in_i = 16'sd1000; in_q = -16'sd1000;
    repeat (2) @(posedge clk); #1; rst = 1;
    @(posedge clk); #1; @(posedge clk); #1; @(posedge clk); #1;
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end
    in_valid = 0; rst = 0; repeat (4) @(posedge clk);
    checking = 1;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][32]; in_last = stim[i][34]; in_i = stim[i][31:16]; in_q = stim[i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_last = 0;
    repeat (6) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_qam_demapper ORDER=%0d (%0d symbols)", ORDER, nout);
    else $display("TEST FAILED tb_phy_qam_demapper ORDER=%0d errors=%0d", ORDER, errors);
    $finish;
  end
endmodule
