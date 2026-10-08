// Self-checking TB: phy_ldpc_enc vs python/ldpc_ref.py::encode (bit-exact codewords), 4 codewords = 2 OFDM symbols,
// 20 filler nibbles (0x5) after every second codeword, random input gaps and output back-pressure.
module tb_phy_ldpc_enc #(parameter int MODE = 1);     // 1: R = 5/6, 16-QAM nibbles (2 symbols); 0: R = 1/2, QPSK words (4 symbols)
  localparam int NCW = 4, NBYTES = MODE ? 225 : 135, NIN = NCW * NBYTES, NOUT = MODE ? 2 * (2 * 540 + 20) : 4 * (1080 + 20);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [7:0] inb [NIN];
  logic [3:0] expn [NOUT];
  logic cfg_mode = MODE[0];
  logic in_valid = 0, in_ready, out_valid, out_ready = 0;
  logic [7:0] in_data = 0; logic [3:0] out_data;
  phy_ldpc_enc dut (.*);

  int errors = 0, nout = 0;
  always @(posedge clk) begin
    out_ready <= ($urandom_range(0, 9) < 8);
    if (!rst && out_valid && out_ready) begin
      if (nout < NOUT && out_data !== expn[nout]) begin errors++; if (errors < 10) $display("nibble %0d got %x exp %x", nout, out_data, expn[nout]); end
      nout++;
    end
  end

  initial begin
    $readmemh(MODE ? "vec/lpe_in.mem" : "vec/lpe0_in.mem", inb);
    $readmemh(MODE ? "vec/lpe_exp.mem" : "vec/lpe0_exp.mem", expn);
    repeat (5) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    for (int i = 0; i < NIN; i++) begin
      while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_data = $urandom; end
      @(posedge clk); #1; in_valid = 1; in_data = inb[i];
      while (!in_ready) begin @(posedge clk); #1; end
    end
    @(posedge clk); #1; in_valid = 0;
    repeat (20000) begin @(posedge clk); if (nout >= NOUT) break; end
    repeat (20) @(posedge clk);
    if (nout !== NOUT) begin errors++; $display("nibbles out %0d != %0d", nout, NOUT); end
    if (errors == 0) $display("TEST PASSED tb_phy_ldpc_enc MODE=%0d (%0d words bit-exact)", MODE, nout);
    else $display("TEST FAILED tb_phy_ldpc_enc errors=%0d", errors);
    $finish;
  end
endmodule
