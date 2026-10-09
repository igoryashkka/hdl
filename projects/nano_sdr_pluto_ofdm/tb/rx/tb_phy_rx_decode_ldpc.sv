// Self-checking TB: phy_rx_decode_ldpc (soft demapper -> deinterleaver -> LDPC decoder -> descrambler) vs the Python chain model
// (python/phy2_fixed_ref.py + ldpc_fixed_ref.py): equalised data bins of a 2-symbol packet on a 2-path channel, per-bin parameters
// preloaded into a RAM model. Checks 900 payload bytes bit-exact, out_first / out_last flags, packet statistics (failed codewords,
// max / total iterations), random input gaps, a second packet back to back.
// MODE = 1: MAX RATE (16-QAM, R = 5/6, 900 bytes), MODE = 0: MAX RANGE (QPSK, R = 1/2, 270 bytes); every packet = header symbol + 2 data symbols,
// the header (always QPSK) is decoded by phy_hdr_dec and must not reach the LDPC decoder.
module tb_phy_rx_decode_ldpc #(parameter int MODE = 1);
  localparam int NB = 1100, NSY = 2, NBYTES = NSY * (MODE ? 450 : 135);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [(NSY + 1) * NB];
  logic [31:0] ptmp [NB];
  logic [28:0] prm [NB];
  logic [7:0]  expb [NBYTES];
  logic [15:0] expst [4];
  logic [7:0]  nsyms = NSY; logic [4:0] cfg_max_iter = 10;
  logic in_hdr = 0; logic mode = MODE[0]; logic cfg_ua = 0; logic cfg_post = 0, p2 = 0; logic [1:0] p2_skip = 0;
  logic raw_valid, raw_st_valid, raw_st_ok, col_valid, dec_busy; logic [7:0] raw_data; logic [4:0] raw_st_iter; logic [5:0] col_idx; logic [59:0] col_hard, col_rel;
  logic hdr_valid, hdr_ok, hdr_mode; logic [7:0] hdr_nsyms; logic [13:0] hdr_conf;
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic [10:0] prm_ra; logic [28:0] prm_rd;
  logic out_valid, out_first, out_last, il_overflow, stat_valid, cw_pulse, cw_fail_pulse;
  logic [7:0] out_data, stat_fail; logic [4:0] stat_iter_max; logic [11:0] stat_iter_sum;
  phy_rx_decode_ldpc dut (.*);
  always_ff @(posedge clk) prm_rd <= prm[prm_ra];

  int errors = 0, nb = 0, npk = 0, nst = 0, nhd = 0;
  always @(posedge clk) if (!rst) begin
    if (out_valid) begin
      if (nb < NBYTES && out_data !== expb[nb]) begin errors++; if (errors < 10) $display("pkt %0d byte %0d got %02x exp %02x", npk, nb, out_data, expb[nb]); end
      if (out_first !== (nb == 0)) begin errors++; $display("first flag at %0d", nb); end
      if (out_last !== (nb == NBYTES - 1)) begin errors++; $display("last flag at %0d", nb); end
      nb++;
      if (out_last) begin if (nb !== NBYTES) begin errors++; $display("packet length %0d", nb); end nb = 0; npk++; end
    end
    if (hdr_valid) begin
      if ({hdr_ok, hdr_mode, hdr_nsyms} !== expst[3][9:0]) begin errors++; $display("header got ok %0d mode %0d nsyms %0d exp %03x", hdr_ok, hdr_mode, hdr_nsyms, expst[3][9:0]); end
      nhd++;
    end
    if (stat_valid) begin
      if ({8'd0, stat_fail} !== expst[0] || {11'd0, stat_iter_max} !== expst[1] || {4'd0, stat_iter_sum} !== expst[2]) begin
        errors++; $display("stats got fail %0d max %0d sum %0d exp %0d %0d %0d", stat_fail, stat_iter_max, stat_iter_sum, expst[0], expst[1], expst[2]);
      end
      nst++;
    end
  end

  task automatic send_packet();
    for (int s = 0; s < NSY + 1; s++) begin
      for (int i = 0; i < NB; i++) begin
        in_hdr = (s == 0);
        while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
        @(posedge clk); #1;
        in_valid = 1; in_first = (i == 0); in_last = (i == NB - 1);
        in_re = stim[s * NB + i][31:16]; in_im = stim[s * NB + i][15:0];
      end
      @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
      repeat (1000) @(posedge clk);                       // symbol spacing (the real chain is much slower)
    end
  endtask

  initial begin
    $readmemh(MODE ? "vec/cdb_in.mem" : "vec/cdq_in.mem", stim);
    $readmemh(MODE ? "vec/cdb_prm.mem" : "vec/cdq_prm.mem", ptmp); for (int i = 0; i < NB; i++) prm[i] = ptmp[i][28:0];
    $readmemh(MODE ? "vec/cdb_exp.mem" : "vec/cdq_exp.mem", expb);
    $readmemh(MODE ? "vec/cdb_stat.mem" : "vec/cdq_stat.mem", expst);
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    send_packet();
    repeat (12000) @(posedge clk);
    send_packet();
    repeat (20000) begin @(posedge clk); if (npk == 2) break; end
    repeat (50) @(posedge clk);
    if (npk !== 2) begin errors++; $display("packets %0d != 2", npk); end
    if (nst !== 2) begin errors++; $display("stat pulses %0d != 2", nst); end
    if (nhd !== 2) begin errors++; $display("header pulses %0d != 2", nhd); end
    if (il_overflow) begin errors++; $display("interleaver overflow"); end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_decode_ldpc MODE=%0d (2 packets x %0d bytes bit-exact, header decoded)", MODE, NBYTES);
    else $display("TEST FAILED tb_phy_rx_decode_ldpc errors=%0d", errors);
    $finish;
  end
endmodule
