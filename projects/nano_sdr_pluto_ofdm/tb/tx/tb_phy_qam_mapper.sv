// Self-checking TB: phy_qam_mapper vs python/qam_ref.py. Run per ORDER (4/16/64) via GEN="-generic_top ORDER=16".
// Covers every constellation point, random symbols, valid gaps w/ garbage, exact latency, reset.
module tb_phy_qam_mapper #(parameter int ORDER = 16);
  localparam int LATENCY = 1, BPS = $clog2(ORDER), MAXN = 4096;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [8:0]      stim_raw [MAXN];
  logic [31:0]     expd [MAXN];
  logic in_valid = 0, in_last = 0; logic [BPS-1:0] in_bits = 0;
  logic out_valid, out_last; logic signed [15:0] out_i, out_q;
  phy_qam_mapper #(.ORDER(ORDER)) dut (.clk, .rst, .in_valid, .in_last, .in_bits, .out_valid, .out_last, .out_i, .out_q);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  logic [LATENCY:0] vpipe = '0, lpipe = '0;
  bit checking = 0;
  always @(posedge clk) begin
    vpipe <= {vpipe[LATENCY-1:0], in_valid & ~rst};
    lpipe <= {lpipe[LATENCY-1:0], in_valid & in_last & ~rst};
  end
  always @(negedge clk) if (checking) begin
    if (out_valid !== vpipe[LATENCY-1]) begin errors++; $display("latency/valid mismatch"); end
    if (out_valid) begin
      if (out_last !== lpipe[LATENCY-1]) begin errors++; $display("last mismatch"); end
      if ({out_i, out_q} !== expd[nout]) begin errors++; $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, out_i, out_q, expd[nout]); end
      nout++;
    end
  end

  initial begin
    string f;
    $sformat(f, "vec/map%0d_stim.mem", ORDER); $readmemh(f, stim_raw);
    $sformat(f, "vec/map%0d_exp.mem", ORDER);  $readmemh(f, expd);
    while (^stim_raw[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    // reset during processing
    @(posedge clk); #1; in_valid = 1; in_bits = '1;
    repeat (2) @(posedge clk); #1; rst = 1;
    @(posedge clk); #1; @(posedge clk); #1;
    if (out_valid !== 0) begin errors++; $display("reset: out_valid not cleared"); end
    in_valid = 0; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      in_valid = stim_raw[i][6]; in_last = stim_raw[i][8]; in_bits = stim_raw[i][BPS-1:0];
    end
    @(posedge clk); #1; in_valid = 0; in_last = 0;
    repeat (5) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_qam_mapper ORDER=%0d (%0d symbols)", ORDER, nout);
    else $display("TEST FAILED tb_phy_qam_mapper ORDER=%0d errors=%0d", ORDER, errors);
    $finish;
  end
endmodule
