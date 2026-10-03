// Self-checking TB: phy_ofdm_mapper vs python/ofdm_ref.py::map_bins (bit-exact incl. pilot-slot flags).
// Tests: 2 symbols, random input valid gaps, start request while busy (must wait), first/last flags,
// no output without start, reset mid-symbol, bin stall when no data (valid gaps).
module tb_phy_ofdm_mapper;
  localparam int N = 2048, MAXN = 8192;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] stim [MAXN];
  logic [35:0] expd [MAXN];
  logic start_valid = 0, start_ready;
  logic in_valid = 0, in_ready; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid, out_pilot, out_first, out_last; logic signed [15:0] out_re, out_im;
  phy_ofdm_mapper dut (.*);

  int errors = 0, nout = 0, ns = 0, ne = 0;
  bit checking = 0;
  always @(posedge clk) if (checking && !rst && out_valid) begin
    if ({out_pilot, out_re, out_im} !== expd[nout][32:0]) begin
      errors++;
      if (errors < 10) $display("DATA mismatch bin %0d got %b/%04x/%04x exp %09x", nout, out_pilot, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[nout]);
    end
    if (out_first !== (nout % N == 0)) begin errors++; $display("first flag wrong at %0d", nout); end
    if (out_last  !== (nout % N == N - 1)) begin errors++; $display("last flag wrong at %0d", nout); end
    nout++;
  end

  int fed = 0;
  // data feeder: random gaps, holds a word until accepted (decision on pre-edge values)
  always @(posedge clk) if (!rst) begin : feeder
    bit acc;
    acc = in_valid && in_ready;
    #1;
    if (acc) fed++;
    if (in_valid && !acc) begin
      // keep
    end else if (fed < ns && $urandom_range(0, 9) < 6) begin
      in_valid = 1; in_re = stim[fed][31:16]; in_im = stim[fed][15:0];
    end else in_valid = 0;
  end

  task automatic start_sym();
    @(posedge clk); #1; start_valid = 1;
    do @(posedge clk); while (!start_ready);
    #1; start_valid = 0;
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) begin stim[i] = 32'bx; expd[i] = 36'bx; end
    $readmemh("vec/ofm_in.mem", stim);
    $readmemh("vec/ofm_exp.mem", expd);
    while (^stim[ns] !== 1'bx) ns++;
    while (^expd[ne] !== 1'bx) ne++;
    repeat (4) @(posedge clk); #1; rst = 0;
    checking = 1; repeat (50) @(posedge clk);
    if (nout !== 0) begin errors++; $display("output without start"); end
    checking = 0;
    // reset mid-symbol
    start_sym(); repeat (700) @(posedge clk);
    #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; fed = 0; in_valid = 0; repeat (3) @(posedge clk);
    // two symbols; the second start request is issued while the first symbol is still running
    checking = 1; nout = 0;
    start_sym();
    start_sym();
    repeat (6000) @(posedge clk);
    if (nout !== ne) begin errors++; $display("count %0d != %0d", nout, ne); end
    if (errors == 0) $display("TEST PASSED tb_phy_ofdm_mapper (%0d bins)", nout);
    else $display("TEST FAILED tb_phy_ofdm_mapper errors=%0d", errors);
    $finish;
  end
endmodule
