// Self-checking TB: phy_rx_decode (demap -> deinterleave -> hard bits -> descramble) vs python/rx_fixed_ref.py::decode_symbols,
// bit-exact bytes for noisy 16-QAM symbols (random bit errors included). The 3-symbol packet is sent twice (checks the
// descrambler seed restart and the symbol/byte counters between packets) with valid gaps and idle time between symbols;
// first/last byte flags; il_overflow stays 0; reset in the middle of a symbol before the checked run.
module tb_phy_rx_decode;
  localparam int ND = 1100, NSY = 3, NB = NSY * 550, MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [33:0] stim [MAXN];
  logic [7:0]  expd [NB];
  logic [7:0]  nsyms = NSY;
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid, out_first, out_last, il_overflow; logic [7:0] out_data;
  phy_rx_decode dut (.*);

  int errors = 0, nout = 0;
  bit checking = 0;
  always @(posedge clk) if (checking && !rst && out_valid) begin
    int k;
    k = nout % NB;
    if (out_data !== expd[k]) begin errors++; if (errors < 10) $display("BYTE mismatch #%0d got %02x exp %02x", nout, out_data, expd[k]); end
    if (out_first !== (k == 0) || out_last !== (k == NB - 1)) begin errors++; if (errors < 10) $display("flag mismatch at byte %0d", nout); end
    nout++;
  end

  task automatic send_symbol(input int sym);
    for (int i = 0; i < ND; i++) begin
      while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
      @(posedge clk); #1;
      in_valid = 1; in_first = stim[sym * ND + i][33]; in_last = stim[sym * ND + i][32]; in_re = stim[sym * ND + i][31:16]; in_im = stim[sym * ND + i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (2500) @(posedge clk);
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 34'bx;
    $readmemh("vec/dec_in.mem", stim);
    $readmemh("vec/dec_exp.mem", expd);
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // reset in the middle of a symbol
    for (int i = 0; i < 500; i++) begin @(posedge clk); #1; in_valid = 1; in_first = (i == 0); in_re = 16'sd3000; in_im = -16'sd3000; end
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    for (int pass = 0; pass < 2; pass++)
      for (int s = 0; s < NSY; s++) send_symbol(s);
    if (nout !== 2 * NB) begin errors++; $display("bytes %0d != %0d", nout, 2 * NB); end
    if (il_overflow) begin errors++; $display("il_overflow"); end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_decode (%0d bytes, 2 packets)", nout);
    else $display("TEST FAILED tb_phy_rx_decode errors=%0d", errors);
    $finish;
  end
endmodule
