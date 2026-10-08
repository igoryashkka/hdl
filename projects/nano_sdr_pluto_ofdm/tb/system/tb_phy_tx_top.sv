// System TB: phy_tx_top (whole TX chain) vs python/tx_ref.py::tx_frame -- bit-exact IQ stream.
// Two back-to-back packets (1100 bytes = 2 data symbols; 700 bytes padded to 2 symbols), random s_valid gaps,
// DAC modelled as a sample strobe every 2nd clock (processing clock = 2 x sample rate, like l_clk = 61.44 MHz for 30.72 MSPS).
// Checks: bit-exact samples, continuity inside a packet (no pull without data once a packet started to play),
// no overflow, pkt_done pulses (2), s_ready low while a packet is buffered, idle output is zero.
module tb_phy_tx_top #(parameter int CODED = 0);
  localparam int SYM = 2192, NA = 4 * SYM, NB = 4 * SYM;
  localparam int P0N = CODED ? 900 : 1100, P1N = CODED ? 500 : 700;     // coded: 450 payload bytes per OFDM symbol
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  logic [7:0]  pkt0 [1100];
  logic [7:0]  pkt1 [700];
  logic [31:0] exp0 [NA];
  logic [31:0] exp1 [NB];
  logic [15:0] gain = 16'd16384;
  logic s_valid = 0, s_ready, s_last = 0; logic [7:0] s_data = 0;
  logic iq_pull = 0, iq_valid, underflow, overflow, pkt_trunc, pkt_done, busy;
  logic signed [15:0] iq_re, iq_im;
  phy_tx_top #(.CODED(CODED)) dut (.clk, .rst, .gain, .s_valid, .s_ready, .s_data, .s_last, .iq_pull, .iq_re, .iq_im, .iq_valid,
                  .underflow, .overflow, .pkt_trunc, .pkt_done, .busy);

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
      nout++;
    end
    if (iq_pull && !iq_valid && nout > 0 && nout != NA && nout < NA + NB) begin
      gap_errs++;
      if (gap_errs < 5) $display("continuity gap: pull without data after %0d samples", nout);
    end
    if (!iq_valid && (iq_re !== 0 || iq_im !== 0)) begin errors++; $display("non-zero IQ while idle"); end
    if (overflow) begin errors++; $display("overflow"); end
    if (underflow) begin errors++; $display("underflow flag"); end
  end

  // pull starts when the first sample is available (the DAC would be idle/zero before)
  always @(posedge clk) if (checking && iq_valid && !pull_en) pull_en <= 1'b1;

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
    if (CODED) begin
      $readmemh("vec/txc_pkt0_in.mem", pkt0); $readmemh("vec/txc_pkt1_in.mem", pkt1);
      $readmemh("vec/txc_pkt0_exp.mem", exp0); $readmemh("vec/txc_pkt1_exp.mem", exp1);
    end else begin
      $readmemh("vec/txt_pkt0_in.mem", pkt0); $readmemh("vec/txt_pkt1_in.mem", pkt1);
      $readmemh("vec/txt_pkt0_exp.mem", exp0); $readmemh("vec/txt_pkt1_exp.mem", exp1);
    end
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    checking = 1;
    send(P0N, 0);
    if (s_ready !== 1'b0 && busy === 1'b0) begin errors++; $display("busy not set after packet"); end
    send(P1N, 1);
    // wait for everything to play out
    repeat (400000) begin
      @(posedge clk);
      if (nout == NA + NB) break;
    end
    repeat (200) @(posedge clk);
    if (nout !== NA + NB) begin errors++; $display("samples %0d != %0d", nout, NA + NB); end
    if (npd !== 2) begin errors++; $display("pkt_done pulses %0d != 2", npd); end
    if (gap_errs != 0) errors += gap_errs;
    if (errors == 0) $display("TEST PASSED tb_phy_tx_top CODED=%0d (%0d samples bit-exact)", CODED, nout);
    else $display("TEST FAILED tb_phy_tx_top errors=%0d", errors);
    $finish;
  end
endmodule
