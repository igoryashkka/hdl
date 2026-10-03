// Self-checking TB: phy_cfo_coarse vs python/sync_ref.py::cfo_inc (bit-exact NCO increment from the Schmidl-Cox P value).
// Tests: boundary P (2^17 ... full 40-bit), random magnitudes 2^17..2^39 in all quadrants, start while busy ignored,
// busy/done handshake, latency, reset during processing.
module tb_phy_cfo_coarse;
  localparam int MAXN = 1024;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [79:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic start = 0; logic signed [39:0] p_re = 0, p_im = 0;
  logic busy, done; logic [31:0] inc;
  phy_cfo_coarse dut (.*);

  int errors = 0, ns = 0, ne = 0, cyc = 0, t_start = 0, lat0 = -1;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 80'bx; expd[i] = 32'bx; end
    $readmemh("vec/cfc_in.mem", stim);
    $readmemh("vec/cfc_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);

    // reset during processing
    #1; p_re = 40'sd1000000; p_im = 40'sd3000000; start = 1; @(posedge clk); #1; start = 0; repeat (6) @(posedge clk);
    #1; rst = 1; @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    if (busy !== 1'b0) begin errors++; $display("busy after reset"); end

    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      p_re = stim[i][79:40]; p_im = stim[i][39:0]; start = 1;
      @(posedge clk); t_start = cyc; #1; start = 0;
      @(posedge clk); #1; if (busy !== 1'b1) begin errors++; $display("busy not asserted"); end
      p_re = 40'sd5; p_im = 40'sd5; start = 1; @(posedge clk); #1; start = 0;       // ignored while busy
      while (!done) @(posedge clk);
      if (inc !== expd[i]) begin
        errors++; if (errors < 10) $display("INC mismatch #%0d P=(%0d,%0d) got %08x exp %08x", i, $signed(stim[i][79:40]), $signed(stim[i][39:0]), inc, expd[i]);
      end
      if (lat0 < 0) lat0 = cyc - t_start;
      else if (cyc - t_start !== lat0) begin errors++; $display("latency not constant"); end
      @(posedge clk);
    end
    if (errors == 0) $display("TEST PASSED tb_phy_cfo_coarse (%0d vectors, latency %0d)", ns, lat0 + 1);
    else $display("TEST FAILED tb_phy_cfo_coarse errors=%0d", errors);
    $finish;
  end
endmodule
