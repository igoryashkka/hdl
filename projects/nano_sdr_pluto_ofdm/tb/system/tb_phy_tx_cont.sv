// System TB: phy_tx_top continuous / streaming frames vs python/tx_ref.py::tx_frame (bit-exact IQ).
// Four back-to-back packets (MODE 0 MAX RANGE: 5400 / 200 / 270 / 40 bytes, MODE 1 MAX RATE: 13500 / 500 / 900 / 40 bytes):
//   0: cont = 1, longer than the 4400-byte ring (wraps, writer back-pressured, reader waits for data)  -> 43 / 33 symbols
//   1: cont = 0, normal packet right behind it (state reset between modes)
//   2: cont = 1, short (2 symbols)    3: cont = 1, 40 bytes (shorter than the 64-byte pre-fill: ends before the frame starts)
// `cont` is switched per packet (sampled with the first byte), cont_nb is presented together with the packet.
// Random s_valid gaps; DAC strobe every 2nd clock. Checks: bit-exact samples, no continuity gap once a frame plays (no pull
// without data), no overflow / underflow, pkt_done pulses (4), idle output zero.
module tb_phy_tx_cont #(parameter int MODE = 0);
  localparam int SYM = 2192;
  localparam int NS0 = MODE ? 33 : 43, NS1 = 5, NS2 = 5, NS3 = 4;
  localparam int N0 = MODE ? 13500 : 5400, N1 = MODE ? 500 : 200, N2 = MODE ? 900 : 270, N3 = 40;
  localparam int TOT = (NS0 + NS1 + NS2 + NS3) * SYM;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [7:0]  pk0 [N0]; logic [7:0] pk1 [N1]; logic [7:0] pk2 [N2]; logic [7:0] pk3 [N3];
  logic [31:0] ex0 [NS0 * SYM]; logic [31:0] ex1 [NS1 * SYM]; logic [31:0] ex2 [NS2 * SYM]; logic [31:0] ex3 [NS3 * SYM];
  logic [15:0] gain = 16'd16384;
  logic cfg_mode = MODE[0], cont = 0; logic [15:0] cont_nb = 0;
  logic s_valid = 0, s_ready, s_last = 0; logic [7:0] s_data = 0;
  logic iq_pull = 0, iq_valid, underflow, overflow, pkt_trunc, pkt_done, busy;
  logic signed [15:0] iq_re, iq_im, iq1_re, iq1_im;
  logic go_fire;
  phy_tx_top #(.CODED(1)) dut (.clk, .rst, .gain, .cfg_mode, .cont, .cont_nb, .s_valid, .s_ready, .s_data, .s_last, .iq_pull, .iq_re, .iq_im, .iq_valid,
    .underflow, .overflow, .pkt_trunc, .pkt_done, .busy, .go_en(1'b1), .go_fire, .w_mode(4'd0), .w_amp(32'd0), .w_phase(32'd0), .w_tau(34'd0),
    .iq1_re, .iq1_im);

  int errors = 0, nout = 0, npd = 0, gap_errs = 0, maxfill = 0;
  bit checking = 0, pull_en = 0, toggle = 0;
  always @(posedge clk) begin toggle <= ~toggle; iq_pull <= pull_en & toggle; end

  function automatic logic [31:0] expect_at(input int n);
    if (n < NS0 * SYM) return ex0[n];
    n -= NS0 * SYM; if (n < NS1 * SYM) return ex1[n];
    n -= NS1 * SYM; if (n < NS2 * SYM) return ex2[n];
    n -= NS2 * SYM; return ex3[n];
  endfunction

  always @(posedge clk) if (checking && !rst) begin
    if (pkt_done) npd++;
    if (iq_pull && iq_valid) begin
      if ({iq_re, iq_im} !== expect_at(nout)) begin
        errors++;
        if (errors < 10) $display("DATA mismatch #%0d (frame sample %0d) got %04x/%04x exp %08x", nout, nout, iq_re & 16'hFFFF, iq_im & 16'hFFFF, expect_at(nout));
      end
      nout++;
    end
    // continuity inside a frame: a pull without data is only legal between frames
    if (iq_pull && !iq_valid && nout > 0 && nout < TOT && (nout % SYM) != 0) begin
      gap_errs++;
      if (gap_errs < 5) $display("continuity gap: pull without data after %0d samples", nout);
    end
    if (!iq_valid && (iq_re !== 0 || iq_im !== 0)) begin errors++; $display("non-zero IQ while idle"); end
    if (overflow) begin errors++; $display("overflow"); end
    if (underflow) begin errors++; $display("underflow flag"); end
    if (pkt_trunc) begin errors++; $display("pkt_trunc"); end
  end
  // the DAC pulls once a frame is available; for the first sample of every frame only
  always @(posedge clk) if (checking && iq_valid && !pull_en) pull_en <= 1'b1;
  always @(posedge clk) if (checking) begin
    int fill; fill = int'(dut.wr_cnt) - int'(dut.rd_idx);
    if (dut.cont_r && fill > maxfill) maxfill = fill;
  end

  task automatic send(input int which);
    int n;
    case (which) 0: n = N0; 1: n = N1; 2: n = N2; default: n = N3; endcase
    @(posedge clk); #1;
    cont = (which != 1); cont_nb = 16'(n);
    repeat (8) @(posedge clk); #1;                       // as in the DMA wrapper: the length is presented well before the first byte
    for (int i = 0; i < n; i++) begin
      while ($urandom_range(0, 9) < 2) begin s_valid = 0; @(posedge clk); #1; end
      s_valid = 1; s_last = (i == n - 1);
      case (which) 0: s_data = pk0[i]; 1: s_data = pk1[i]; 2: s_data = pk2[i]; default: s_data = pk3[i]; endcase
      do @(posedge clk); while (!s_ready);
      #1;
    end
    s_valid = 0; s_last = 0;
  endtask

  initial begin
    string t; t = MODE ? "cr" : "cq";
    for (int k = 0; k < 4; k++) begin
      string f;
      $sformat(f, "vec/%s_pkt%0d_in.mem", t, k);
      case (k) 0: $readmemh(f, pk0); 1: $readmemh(f, pk1); 2: $readmemh(f, pk2); default: $readmemh(f, pk3); endcase
      $sformat(f, "vec/%s_pkt%0d_exp.mem", t, k);
      case (k) 0: $readmemh(f, ex0); 1: $readmemh(f, ex1); 2: $readmemh(f, ex2); default: $readmemh(f, ex3); endcase
    end
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    checking = 1;
    send(0);
    send(1);
    send(2);
    send(3);
    repeat (1500000) begin @(posedge clk); if (nout == TOT) break; end
    repeat (200) @(posedge clk);
    if (nout !== TOT) begin errors++; $display("samples %0d != %0d", nout, TOT); end
    if (npd !== 4) begin errors++; $display("pkt_done pulses %0d != 4", npd); end
    if (maxfill < 4000) begin errors++; $display("the ring never filled (max %0d): wrap / back-pressure not exercised", maxfill); end
    if (gap_errs != 0) errors += gap_errs;
    if (errors == 0) $display("TEST PASSED tb_phy_tx_cont MODE=%0d (%0d samples bit-exact, 4 frames, ring fill max %0d)", MODE, nout, maxfill);
    else $display("TEST FAILED tb_phy_tx_cont errors=%0d", errors);
    $finish;
  end
endmodule
