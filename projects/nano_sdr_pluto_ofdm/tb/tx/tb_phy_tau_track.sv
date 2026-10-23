// Self-checking TB: phy_tau_track vs python/bf_ref.py (generate_vectors_bf.py): random set / strobe / rho (incl. full-range rho,
// 48-bit wrap and +-32767 saturation of tau_now), tau_now checked after every clock.
module tb_phy_tau_track;
  localparam int MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [49:0] stim [MAXN];
  logic [15:0] expd [MAXN];
  logic strobe = 0, set = 0; logic signed [15:0] tau_set = 0; logic signed [31:0] rho = 0;
  logic signed [15:0] tau_now;
  phy_tau_track dut (.*);
  int errors = 0, n = 0;
  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 50'bx;
    $readmemh("vec/bf_tt_stim.mem", stim); $readmemh("vec/bf_tt_exp.mem", expd);
    repeat (3) @(posedge clk); #1; rst = 0;
    while (^stim[n] !== 1'bx) begin
      {set, strobe, tau_set, rho} = stim[n];
      @(posedge clk); #1;
      if (tau_now !== expd[n]) begin errors++; if (errors < 10) $display("mismatch #%0d got %04x exp %04x", n, tau_now & 16'hFFFF, expd[n]); end
      n++;
    end
    if (errors == 0) $display("TEST PASSED tb_phy_tau_track (%0d clocks)", n);
    else $display("TEST FAILED tb_phy_tau_track errors=%0d", errors);
    $finish;
  end
endmodule
