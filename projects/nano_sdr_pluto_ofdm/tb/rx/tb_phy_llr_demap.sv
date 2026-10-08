// Self-checking TB: phy_llr_demap vs python/phy2_fixed_ref.py::demap_soft (bit-exact 6 bit LLRs), 3 symbols x 1100 bins, random valid gaps
// (garbage on idle cycles), first/last flags, parameter RAM modelled with a 1-cycle synchronous read.
module tb_phy_llr_demap;
  localparam int NB = 1100, NS = 3;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [NS * NB];
  logic [23:0] expd [NS * NB];
  logic [28:0] prm [NB];
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic [10:0] rd_addr; logic [28:0] rd_data;
  logic out_valid, out_first, out_last; logic signed [5:0] out_llr [4];
  phy_llr_demap dut (.*);
  always_ff @(posedge clk) rd_data <= prm[rd_addr];

  int errors = 0, nout = 0;
  always @(posedge clk) if (!rst && out_valid) begin
    logic [23:0] g;
    g = {out_llr[0][5:0], out_llr[1][5:0], out_llr[2][5:0], out_llr[3][5:0]};
    if (nout < NS * NB) begin
      if (g !== expd[nout]) begin errors++; if (errors < 10) $display("bin %0d got %06x exp %06x", nout, g, expd[nout]); end
      if (out_first !== (nout % NB == 0) || out_last !== (nout % NB == NB - 1)) begin errors++; $display("flags at %0d", nout); end
    end
    nout++;
  end

  initial begin
    for (int i = 0; i < NB; i++) prm[i] = 29'd0;
    begin logic [31:0] t [NB]; $readmemh("vec/llr_prm.mem", t); for (int i = 0; i < NB; i++) prm[i] = t[i][28:0]; end
    $readmemh("vec/llr_in.mem", stim);
    $readmemh("vec/llr_exp.mem", expd);
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    for (int s = 0; s < NS; s++) begin
      for (int i = 0; i < NB; i++) begin
        while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
        @(posedge clk); #1;
        in_valid = 1; in_first = (i == 0); in_last = (i == NB - 1);
        in_re = stim[s * NB + i][31:16]; in_im = stim[s * NB + i][15:0];
      end
      @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0; repeat (5) @(posedge clk);
    end
    repeat (20) @(posedge clk);
    if (nout !== NS * NB) begin errors++; $display("outputs %0d != %0d", nout, NS * NB); end
    if (errors == 0) $display("TEST PASSED tb_phy_llr_demap (%0d bins bit-exact)", nout);
    else $display("TEST FAILED tb_phy_llr_demap errors=%0d", errors);
    $finish;
  end
endmodule
