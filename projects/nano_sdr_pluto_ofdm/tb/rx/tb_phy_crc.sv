// Self-checking TB: phy_crc vs python/crc_ref.py. Good frames -> ok=1, 1-bit-corrupted frames -> ok=0,
// register value bit-exact, done pulses exactly LATENCY after in_last, valid gaps, reset during processing.
module tb_phy_crc;
  localparam int LATENCY = 1, MAXN = 4096;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [11:0] stim [MAXN];
  logic [35:0] expd [MAXN];
  logic in_valid = 0, in_first = 0, in_last = 0; logic [7:0] in_data = 0;
  logic done, ok; logic [31:0] crc;
  phy_crc dut (.clk, .rst, .in_valid, .in_first, .in_last, .in_data, .done, .crc, .ok);

  int errors = 0, nfr = 0, ns = 0, ne = 0;
  logic lpipe = 0;
  bit checking = 0;
  always @(posedge clk) lpipe <= in_valid & in_last & ~rst;
  always @(negedge clk) if (checking) begin
    if (done !== lpipe) begin errors++; $display("done latency mismatch"); end
    if (done) begin
      if ({ok, crc} !== expd[nfr][32:0]) begin errors++; $display("CRC mismatch frame %0d got ok=%b crc=%08x exp %09x", nfr, ok, crc, expd[nfr][32:0]); end
      nfr++;
    end
  end

  initial begin
    $readmemh("vec/crc_stim.mem", stim);
    $readmemh("vec/crc_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    @(posedge clk); #1; in_valid = 1; in_first = 1; in_data = 8'h12;
    repeat (3) begin @(posedge clk); #1; in_first = 0; end
    rst = 1; @(posedge clk); #1; @(posedge clk); #1;
    if (done !== 0) begin errors++; $display("reset: done not cleared"); end
    in_valid = 0; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      in_valid = stim[i][8]; in_first = stim[i][9]; in_last = stim[i][10]; in_data = stim[i][7:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (5) @(posedge clk);
    if (nfr !== ne) begin errors++; $display("frames %0d != %0d", nfr, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_crc (%0d frames)", nfr);
    else $display("TEST FAILED tb_phy_crc errors=%0d", errors);
    $finish;
  end
endmodule
