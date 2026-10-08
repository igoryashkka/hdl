// Self-checking TB: PHY header symbol. phy_hdr_gen vs python/hdr_ref.py::tx_bins (3 headers, 1100 bins each, bit-exact I/Q levels, output
// back-pressure), phy_hdr_dec vs hdr_ref.decode (clean, noisy, pure-noise input: ok flag, mode, nsyms, confidence).
module tb_phy_hdr;
  localparam int NB = 1100;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  // ---- generator
  logic        g_start = 0, g_mode = 0; logic [7:0] g_nsyms = 0;
  logic        g_valid, g_ready = 0, g_busy; logic signed [15:0] g_i, g_q;
  phy_hdr_gen u_gen (.clk, .rst, .start(g_start), .mode(g_mode), .nsyms(g_nsyms), .out_valid(g_valid), .out_ready(g_ready), .out_i(g_i), .out_q(g_q), .busy(g_busy));
  logic [31:0] gexp [3 * NB];
  logic [8:0]  gcfg [3];
  // ---- decoder
  logic        d_valid = 0, d_first = 0, d_last = 0; logic signed [5:0] d_l0 = 0, d_l1 = 0;
  logic        o_valid, o_ok, o_mode; logic [7:0] o_nsyms; logic [13:0] o_conf;
  phy_hdr_dec u_dec (.clk, .rst, .in_valid(d_valid), .in_first(d_first), .in_last(d_last), .in_llr0(d_l0), .in_llr1(d_l1),
                     .o_valid, .o_ok, .o_mode, .o_nsyms, .o_conf);
  logic [11:0] hin [3 * NB];
  logic [23:0] hexp [3];

  int errors = 0, ng = 0, nd = 0;
  always @(posedge clk) begin
    g_ready <= ($urandom_range(0, 9) < 7);
    if (!rst && g_valid && g_ready) begin
      if (ng < 3 * NB && {g_i, g_q} !== gexp[ng]) begin errors++; if (errors < 10) $display("gen bin %0d got %08x exp %08x", ng, {g_i, g_q}, gexp[ng]); end
      ng++;
    end
    if (!rst && o_valid) begin
      if ({o_ok, o_mode, o_nsyms, o_conf} !== hexp[nd]) begin errors++; $display("dec %0d got %06x exp %06x", nd, {o_ok, o_mode, o_nsyms, o_conf}, hexp[nd]); end
      nd++;
    end
  end

  initial begin
    $readmemh("vec/hdg_exp.mem", gexp); $readmemh("vec/hdg_cfg.mem", gcfg);
    $readmemh("vec/hdd_in.mem", hin);   $readmemh("vec/hdd_exp.mem", hexp);
    repeat (5) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    for (int h = 0; h < 3; h++) begin
      @(posedge clk); #1; g_start = 1; g_mode = gcfg[h][8]; g_nsyms = gcfg[h][7:0];
      @(posedge clk); #1; g_start = 0;
      while (ng < (h + 1) * NB) @(posedge clk);
      repeat (4) @(posedge clk);
    end
    for (int h = 0; h < 3; h++) begin
      for (int i = 0; i < NB; i++) begin
        while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; d_valid = 0; d_first = $urandom; d_last = $urandom; d_l0 = $urandom; d_l1 = $urandom; end
        @(posedge clk); #1; d_valid = 1; d_first = (i == 0); d_last = (i == NB - 1);
        d_l0 = hin[h * NB + i][11:6]; d_l1 = hin[h * NB + i][5:0];
      end
      @(posedge clk); #1; d_valid = 0; d_first = 0; d_last = 0; repeat (6) @(posedge clk);
    end
    repeat (10) @(posedge clk);
    if (ng !== 3 * NB) begin errors++; $display("generator bins %0d != %0d", ng, 3 * NB); end
    if (nd !== 3) begin errors++; $display("decoder results %0d != 3", nd); end
    if (errors == 0) $display("TEST PASSED tb_phy_hdr (generator %0d bins, decoder 3 headers bit-exact)", ng);
    else $display("TEST FAILED tb_phy_hdr errors=%0d", errors);
    $finish;
  end
endmodule
