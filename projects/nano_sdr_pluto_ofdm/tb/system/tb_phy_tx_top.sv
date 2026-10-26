// System TB: phy_tx_top (whole TX chain) vs python/tx_ref.py::tx_frame -- bit-exact IQ stream.
// Two back-to-back packets (1100 bytes = 2 data symbols; 700 bytes padded to 2 symbols), random s_valid gaps,
// DAC modelled as a sample strobe every 2nd clock (processing clock = 2 x sample rate, like l_clk = 61.44 MHz for 30.72 MSPS).
// Checks: bit-exact samples, continuity inside a packet (no pull without data once a packet started to play),
// no overflow, pkt_done pulses (2), s_ready low while a packet is buffered, idle output is zero.
// CODED = 1: dual-mode frame [sync][LTS][header][2 data symbols]; MODE = 1 MAX RATE (16-QAM, LDPC 5/6, 900 / 500 byte packets),
// MODE = 0 MAX RANGE (QPSK, LDPC 1/2, 270 / 200 byte packets).
// BF = 1 (beamforming, python/bf_ref.py::tx_frame_bf, MAX RANGE): two output channels with per-packet weights (packet 0: ch0
// bypass, ch1 weighted; packet 1: ch0 weighted, ch1 muted), both channels checked bit-exact; packet 1 is held back with go_en = 0
// for 30000 clocks after it is buffered (timed launch): no sample may come out early, go_fire must coincide with the release.
module tb_phy_tx_top #(parameter int CODED = 0, parameter int MODE = 1, parameter int BF = 0);
  localparam int SYM = 2192, NA = (CODED ? 5 : 4) * SYM, NB = (CODED ? 5 : 4) * SYM;
  localparam int P0N = CODED ? (MODE ? 900 : 270) : 1100, P1N = CODED ? (MODE ? 500 : 200) : 700;     // coded: 450 / 135 payload bytes per OFDM symbol
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [7:0]  pkt0 [1100];
  logic [7:0]  pkt1 [700];
  logic [31:0] exp0 [NA];
  logic [31:0] exp1 [NB];
  logic [31:0] e1x0 [NA];
  logic [31:0] e1x1 [NB];
  logic [51:0] wcfg [4];
  logic go_en = 1'b1, go_fire; logic [3:0] w_mode = 0; logic [31:0] w_amp = 0, w_phase = 0; logic [33:0] w_tau = 0;
  logic signed [15:0] iq1_re, iq1_im;
  int n_fire = 0, t_release = -1, t_fire1 = -1, cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;
  always @(posedge clk) if (go_fire) begin n_fire++; if (n_fire == 2) t_fire1 = cyc; end
  logic [15:0] gain = 16'd16384;
  logic cfg_mode = MODE[0];
  logic s_valid = 0, s_ready, s_last = 0; logic [7:0] s_data = 0;
  logic iq_pull = 0, iq_valid, underflow, overflow, pkt_trunc, pkt_done, busy;
  logic signed [15:0] iq_re, iq_im;
  phy_tx_top #(.CODED(CODED), .BF(BF)) dut (.clk, .rst, .gain, .cfg_mode, .cont(1'b0), .cont_nb(16'd0), .s_valid, .s_ready, .s_data, .s_last, .iq_pull, .iq_re, .iq_im, .iq_valid,
                  .underflow, .overflow, .pkt_trunc, .pkt_done, .busy, .go_en, .go_fire, .w_mode, .w_amp, .w_phase, .w_tau, .iq1_re, .iq1_im);

  int errors = 0, nout = 0, npd = 0, gap_errs = 0;
  bit checking = 0;
  bit pull_en = 0;
  bit toggle = 0;

  // sample strobe: every 2nd clock once enabled
  always @(posedge clk) begin
    toggle <= ~toggle;
    iq_pull <= pull_en & toggle;
  end

  always @(posedge clk) if (checking && !rst) begin
    if (pkt_done) npd++;
    if (iq_pull && iq_valid) begin
      logic [31:0] e;
      e = (nout < NA) ? exp0[nout] : exp1[nout - NA];
      if ({iq_re, iq_im} !== e) begin
        errors++;
        if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, iq_re & 16'hFFFF, iq_im & 16'hFFFF, e);
      end
      if (BF) begin
        e = (nout < NA) ? e1x0[nout] : e1x1[nout - NA];
        if ({iq1_re, iq1_im} !== e) begin
          errors++;
          if (errors < 10) $display("CH1 mismatch #%0d got %04x/%04x exp %08x", nout, iq1_re & 16'hFFFF, iq1_im & 16'hFFFF, e);
        end
      end
      nout++;
    end
    if (iq_pull && !iq_valid && nout > 0 && nout != NA && nout < NA + NB && !(BF && nout == NA)) begin
      gap_errs++;
      if (gap_errs < 5) $display("continuity gap: pull without data after %0d samples", nout);
    end
    if (!iq_valid && (iq_re !== 0 || iq_im !== 0 || iq1_re !== 0 || iq1_im !== 0)) begin errors++; $display("non-zero IQ while idle"); end
    if (BF && t_release < 0 && nout > NA) begin errors++; $display("packet 1 played before go_en"); end
    if (overflow) begin errors++; $display("overflow"); end
    if (underflow) begin errors++; $display("underflow flag"); end
  end

  // pull starts when the first sample is available (the DAC would be idle/zero before)
  always @(posedge clk) if (checking && iq_valid && !pull_en) pull_en <= 1'b1;

  task automatic setw(input int k);
    #1;
    for (int c = 0; c < 2; c++) begin
      w_mode[2*c +: 2]   = wcfg[2*k + c][50:49];
      w_amp[16*c +: 16]  = wcfg[2*k + c][48:33];
      w_phase[16*c +: 16] = wcfg[2*k + c][32:17];
      w_tau[17*c +: 17]  = wcfg[2*k + c][16:0];
    end
  endtask

  task automatic send(input int n, input int which);
    @(posedge clk); #1;
    for (int i = 0; i < n; i++) begin
      while ($urandom_range(0, 9) < 2) begin s_valid = 0; @(posedge clk); #1; end
      s_valid = 1; s_data = which ? pkt1[i] : pkt0[i]; s_last = (i == n - 1);
      do @(posedge clk); while (!s_ready);   // accepted at this edge (pre-edge s_ready)
      #1;
    end
    s_valid = 0; s_last = 0;
  endtask

  initial begin
    string f;
    if (BF) begin
      $readmemh("vec/bf_txt_pkt0_in.mem", pkt0); $readmemh("vec/bf_txt_pkt1_in.mem", pkt1);
      $readmemh("vec/bf_txt_pkt0_ch0_exp.mem", exp0); $readmemh("vec/bf_txt_pkt1_ch0_exp.mem", exp1);
      $readmemh("vec/bf_txt_pkt0_ch1_exp.mem", e1x0); $readmemh("vec/bf_txt_pkt1_ch1_exp.mem", e1x1);
      $readmemh("vec/bf_txt_cfg.mem", wcfg);
    end else if (CODED) begin
      $readmemh(MODE ? "vec/txc_pkt0_in.mem" : "vec/txq_pkt0_in.mem", pkt0); $readmemh(MODE ? "vec/txc_pkt1_in.mem" : "vec/txq_pkt1_in.mem", pkt1);
      $readmemh(MODE ? "vec/txc_pkt0_exp.mem" : "vec/txq_pkt0_exp.mem", exp0); $readmemh(MODE ? "vec/txc_pkt1_exp.mem" : "vec/txq_pkt1_exp.mem", exp1);
    end else begin
      $readmemh("vec/txt_pkt0_in.mem", pkt0); $readmemh("vec/txt_pkt1_in.mem", pkt1);
      $readmemh("vec/txt_pkt0_exp.mem", exp0); $readmemh("vec/txt_pkt1_exp.mem", exp1);
    end
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    checking = 1;
    if (BF) setw(0);
    send(P0N, 0);
    if (s_ready !== 1'b0 && busy === 1'b0) begin errors++; $display("busy not set after packet"); end
    if (BF) begin
      wait (s_ready === 1'b1);                // packet 0 taken -> its weights are latched
      setw(1); go_en = 1'b0;
    end
    send(P1N, 1);
    if (BF) begin
      repeat (30000) @(posedge clk);
      if (n_fire != 1) begin errors++; $display("go_fire while go_en = 0 (%0d)", n_fire); end
      #1; go_en = 1'b1; t_release = cyc;
      @(posedge clk); @(posedge clk);
      if (t_fire1 < 0 || t_fire1 > t_release + 1) begin errors++; $display("go_fire %0d not at the release %0d", t_fire1, t_release); end
    end
    // wait for everything to play out
    repeat (400000) begin
      @(posedge clk);
      if (nout == NA + NB) break;
    end
    repeat (200) @(posedge clk);
    if (nout !== NA + NB) begin errors++; $display("samples %0d != %0d", nout, NA + NB); end
    if (npd !== 2) begin errors++; $display("pkt_done pulses %0d != 2", npd); end
    if (gap_errs != 0) errors += gap_errs;
    if (errors == 0) $display("TEST PASSED tb_phy_tx_top CODED=%0d MODE=%0d BF=%0d (%0d samples bit-exact%s)", CODED, MODE, BF, nout, BF ? ", 2 channels" : "");
    else $display("TEST FAILED tb_phy_tx_top errors=%0d", errors);
    $finish;
  end
endmodule
