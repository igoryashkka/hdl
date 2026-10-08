// Self-checking TB: phy_noise_est vs python/phy2_fixed_ref.py::noise_code (bit-exact guard-bin energy and log code).
// 3 FFT frames (2048 bins): frames 0 and 2 measured (en = 1), frame 1 (en = 0, all zero) must be ignored; random valid gaps.
module tb_phy_noise_est;
  localparam int NB = 2048;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [3 * NB];
  logic [53:0] expd [2];
  logic en = 0, in_valid = 0, in_first = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic nu_valid; logic signed [12:0] lg_nu; logic [40:0] noise_sum;
  phy_noise_est dut (.*);
  int errors = 0, nres = 0;
  always @(posedge clk) if (!rst && nu_valid) begin
    if (nres < 2) begin
      if ({lg_nu, noise_sum} !== expd[nres]) begin errors++; $display("result %0d got code %0d sum %0d exp code %0d sum %0d", nres, lg_nu, noise_sum, $signed(expd[nres][53:41]), expd[nres][40:0]); end
    end
    nres++;
  end
  initial begin
    $readmemh("vec/nse_in.mem", stim);
    $readmemh("vec/nse_exp.mem", expd);
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    for (int f = 0; f < 3; f++) begin
      for (int b = 0; b < NB; b++) begin
        while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_re = $urandom; in_im = $urandom; end
        @(posedge clk); #1;
        in_valid = 1; in_first = (b == 0); en = (f != 1);
        in_re = stim[f * NB + b][31:16]; in_im = stim[f * NB + b][15:0];
      end
      @(posedge clk); #1; in_valid = 0; in_first = 0; repeat (30) @(posedge clk);
    end
    if (nres !== 2) begin errors++; $display("results %0d != 2", nres); end
    if (errors == 0) $display("TEST PASSED tb_phy_noise_est (2 frames bit-exact, 1 ignored)");
    else $display("TEST FAILED tb_phy_noise_est errors=%0d", errors);
    $finish;
  end
endmodule
