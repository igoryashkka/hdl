// Self-checking TB: phy_ldpc_dec vs python/ldpc_fixed_ref.py (bit-exact info bytes, iteration count, converged flag).
// 10 codewords back to back (clean, marginal, failing at the iteration limit, all-zero LLRs, noise only), random input gaps,
// output checked byte by byte (225 per codeword), first/last flags, status with the last byte, load/decode/output overlap.
module tb_phy_ldpc_dec #(parameter int MODE = 1);     // 1: R = 5/6 (225 bytes / codeword), 0: R = 1/2 (135 bytes)
  localparam int NCW = 10, NW = 540, NB = MODE ? 225 : 135, MAXIT = 10;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [23:0] stim [NCW * NW];
  logic [8:0]  expd [NCW * (NB + 1)];
  logic [4:0]  cfg_max_iter = MAXIT;
  logic        cfg_cs = MODE[0];
  logic in_valid = 0, in_ready;
  logic signed [5:0] in_llr [4];
  logic out_valid, out_first, out_last, st_valid, st_ok, busy;
  logic [7:0] out_data; logic [4:0] st_iter;
  phy_ldpc_dec dut (.*);

  int errors = 0, ncw_out = 0, nb_out = 0, cyc = 0, last_st = 0;
  always @(posedge clk) cyc <= cyc + 1;
  // decode time report (parsed by experiments/rtl_runs.py): cycles between consecutive status pulses = decode time when the decoder is the bottleneck
  always @(posedge clk) if (st_valid) begin $display("LDPCSTAT mode=%0d cw=%0d iter=%0d ok=%0d dt=%0d", MODE, ncw_out, st_iter, st_ok, cyc - last_st); last_st = cyc; end
  always @(posedge clk) if (!rst) begin
    if (out_valid) begin
      if (ncw_out < NCW) begin
        if (out_data !== expd[ncw_out * (NB + 1) + nb_out][7:0]) begin
          errors++; if (errors < 10) $display("cw %0d byte %0d got %02x exp %02x", ncw_out, nb_out, out_data, expd[ncw_out * (NB + 1) + nb_out][7:0]);
        end
        if (out_first !== (nb_out == 0)) begin errors++; $display("first flag cw %0d byte %0d", ncw_out, nb_out); end
        if (out_last !== (nb_out == NB - 1)) begin errors++; $display("last flag cw %0d byte %0d", ncw_out, nb_out); end
      end
      nb_out++;
      if (out_last) begin
        if (nb_out !== NB) begin errors++; $display("cw %0d: %0d bytes", ncw_out, nb_out); end
        nb_out = 0;
      end
    end
    if (st_valid) begin
      if (ncw_out < NCW) begin
        if ({st_ok, 3'b0, st_iter} !== {expd[ncw_out * (NB + 1) + NB][8], 3'b0, expd[ncw_out * (NB + 1) + NB][4:0]}) begin
          errors++; $display("cw %0d status ok/iter got %0d/%0d exp %0d/%0d", ncw_out, st_ok, st_iter, expd[ncw_out * (NB + 1) + NB][8], expd[ncw_out * (NB + 1) + NB][4:0]);
        end
      end
      ncw_out++;
    end
  end

  initial begin
    $readmemh(MODE ? "vec/ldp_in.mem" : "vec/ldp0_in.mem", stim);
    $readmemh(MODE ? "vec/ldp_exp.mem" : "vec/ldp0_exp.mem", expd);
    repeat (6) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    for (int c = 0; c < NCW; c++)
      for (int w = 0; w < NW; w++) begin
        while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; for (int j = 0; j < 4; j++) in_llr[j] = $urandom; end
        @(posedge clk); #1;
        in_valid = 1;
        for (int j = 0; j < 4; j++) in_llr[j] = stim[c * NW + w][6 * (3 - j) +: 6];
        while (!in_ready) begin @(posedge clk); #1; end     // wait (data held) until a bank is free
      end
    @(posedge clk); #1; in_valid = 0;
    repeat (200000) begin @(posedge clk); if (ncw_out == NCW) break; end
    repeat (50) @(posedge clk);
    if (ncw_out !== NCW) begin errors++; $display("codewords out %0d != %0d", ncw_out, NCW); end
    if (errors == 0) $display("TEST PASSED tb_phy_ldpc_dec MODE=%0d (%0d codewords bit-exact)", MODE, NCW);
    else $display("TEST FAILED tb_phy_ldpc_dec errors=%0d", errors);
    $finish;
  end
endmodule
