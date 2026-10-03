// Self-checking TB: phy_cordic (vectoring) vs python/sync_ref.py::cordic_vec, bit-exact angle (2^32 = 2*pi).
// Tests: boundary points (0,0), full-scale in every quadrant, +-1, small random vectors, 500 random 18-bit vectors,
// exact latency (done = NITER+1 cycles after start), start ignored while busy, reset during iteration.
module tb_phy_cordic;
  localparam int XW = 18, NITER = 24, MAXN = 2048;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [35:0] stim [MAXN];
  logic [31:0] expd [MAXN];
  logic start = 0; logic signed [XW-1:0] x = 0, y = 0;
  logic busy, done; logic [31:0] angle;
  phy_cordic #(.XW(XW), .NITER(NITER)) dut (.*);

  int errors = 0, ns = 0, ne = 0, cyc = 0, t_start = 0;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 36'bx; expd[i] = 32'bx; end
    $readmemh("vec/cor_in.mem", stim);
    $readmemh("vec/cor_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);

    // reset during iteration
    #1; x = 18'sd1000; y = 18'sd500; start = 1; @(posedge clk); #1; start = 0; repeat (5) @(posedge clk);
    #1; rst = 1; @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    if (busy !== 1'b0) begin errors++; $display("busy after reset"); end

    for (int i = 0; i < ns; i++) begin
      @(posedge clk); #1;
      x = stim[i][35:18]; y = stim[i][17:0]; start = 1;
      @(posedge clk); t_start = cyc; #1;       // start sampled at this edge
      start = 0;
      // a second start while busy must be ignored: pulse with different data
      @(posedge clk); #1; x = 18'sd77; y = -18'sd77; start = 1; @(posedge clk); #1; start = 0;
      while (!done) @(posedge clk);
      // done is sampled right at this edge (pre-NBA values are what we see in the active region)
      if (angle !== expd[i]) begin
        errors++; if (errors < 10) $display("ANGLE mismatch #%0d (%0d,%0d) got %08x exp %08x", i, $signed(stim[i][35:18]), $signed(stim[i][17:0]), angle, expd[i]);
      end
      if (cyc - t_start !== NITER + 1) begin errors++; if (errors < 10) $display("latency %0d (exp %0d) #%0d", cyc - t_start, NITER + 1, i); end
      @(posedge clk);
    end
    if (errors == 0) $display("TEST PASSED tb_phy_cordic (%0d vectors, latency %0d)", ns, NITER + 1);
    else $display("TEST FAILED tb_phy_cordic errors=%0d", errors);
    $finish;
  end
endmodule
