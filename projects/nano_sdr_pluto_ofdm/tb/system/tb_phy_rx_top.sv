// System TB: phy_rx_top (whole RX chain) on an ADC-like sample stream from the Python TX + channel model:
//   noise lead (1200) | packet A (1100 bytes, 35 dB, CFO +9 kHz) | idle noise | packet B (1100 bytes, 30 dB, CFO -7 kHz, 2-path)
// The DAC/ADC strobe is every 2nd clock (processing clock = 2 x sample rate). Checks, per packet on the AXI-stream:
//   header magic/version/nbytes/seq, flags == 0, n_best and NCO increment bit-exact vs python/sync_ref.py (detector + CORDIC),
//   payload bytes equal to the transmitted payload (uncoded 16-QAM, expected error-free at these SNRs),
//   tlast only on the final beat, exactly 2 packets, 2 detections, no watchdog, no drops.
// CODED = 1, MODE selects the stream: 1 = both packets MAX RATE (16-QAM, R = 5/6, 900 bytes), 0 = both MAX RANGE (QPSK, R = 1/2, 270 bytes),
// 2 = mode switching between packets (A: MAX RATE 900 bytes, B: MAX RANGE 270 bytes). The mode is taken from the header symbol; cfg_mode (the
// fallback) is set to the wrong value on purpose.
module tb_phy_rx_top #(parameter bit CODED = 1'b0, parameter int MODE = 1);
  localparam int NSYMS = 2, NPKT = 2;
  localparam int PB0 = CODED ? (MODE == 0 ? 270 : 900) : 1100, PB1 = CODED ? (MODE == 1 ? 900 : 270) : 1100;
  localparam int NH = CODED ? 6 : 3, NBEATS0 = NH + (PB0 + 7) / 8, NBEATS1 = NH + (PB1 + 7) / 8, NBMAX = (NBEATS0 > NBEATS1) ? NBEATS0 : NBEATS1;
  localparam bit PM0 = (MODE == 0) ? 1'b0 : 1'b1, PM1 = (MODE == 1) ? 1'b1 : 1'b0;      // MODE_ID of packet A / B
  localparam int NS = CODED ? 35129 : 30745;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] samples [NS];
  logic [7:0]  payload [PB0 + PB1];
  logic [31:0] ev [NPKT * 4];             // per packet: n_best, cfo_inc, rssi code, python evm (RTL NCO phase origin differs slightly)
  logic [7:0]  cfg_nsyms = NSYMS;
  logic [31:0] cfg_rmin = 32'd262144;
  logic signed [3:0] cfg_gain_sh = 0;
  logic in_valid = 0; logic signed [15:0] in_i = 0, in_q = 0;
  logic m_axis_valid, m_axis_ready = 0, m_axis_last; logic [63:0] m_axis_data;
  logic [15:0] st_det_count, st_pkt_count, st_drop_count, st_wd_count; logic [7:0] st_flags; logic st_busy;
  logic cfg_smooth = 1;
  logic cfg_hdr_en = 1, cfg_mode = (MODE == 1) ? 1'b0 : 1'b1;
  logic st_mode, st_hdr_ok, st_hdr_mism; logic [13:0] st_hdr_conf;
  logic cfg_mmse = 1; logic [4:0] cfg_max_iter = 10; logic signed [12:0] cfg_bad_thr = 106; logic cfg_ft_en = 1; logic [7:0] cfg_tau_tgt = 56;
  logic signed [19:0] st_tau_q8; logic signed [7:0] st_w0_adj;
  logic [15:0] st_snr_avg, st_snr_min, st_bad, st_noise, st_cw_count, st_cwfail_count; logic [7:0] st_ldpc_fail; logic [4:0] st_ldpc_imax; logic [11:0] st_ldpc_isum;
  logic [15:0] st_rssi, st_angle, st_seq; logic [31:0] st_evm, st_cfo_inc, st_nbest; logic st_pkt_pulse;
  phy_rx_top #(.CODED(CODED)) dut (.*);

  int errors = 0, nbeat = 0, npkt = 0, byte_errs = 0;
  logic [63:0] pk [NPKT][NBMAX];
  int pk_len [NPKT];
  logic [63:0] held; bit has_held = 0;

  always @(posedge clk) if (!rst) begin
    if (has_held && !(m_axis_valid && m_axis_data === held)) begin errors++; $display("stream changed while stalled"); end
    has_held <= m_axis_valid && !m_axis_ready; held <= m_axis_data;
    if (m_axis_valid && m_axis_ready) begin
      if (npkt < NPKT && nbeat < NBMAX) pk[npkt][nbeat] = m_axis_data;
      nbeat++;
      if (m_axis_last) begin
        if (npkt < NPKT) pk_len[npkt] = nbeat;
        npkt++; nbeat = 0;
      end
    end
  end
  always @(posedge clk) m_axis_ready <= ($urandom_range(0, 9) < 7);

  // sample strobe: one valid every 2nd clock
  initial begin
    string f;
    if (CODED) begin
      if (MODE == 1) begin $readmemh("vec/rxc_in.mem", samples); $readmemh("vec/rxc_pay.mem", payload); $readmemh("vec/rxc_ev.mem", ev); end
      else if (MODE == 0) begin $readmemh("vec/rxq_in.mem", samples); $readmemh("vec/rxq_pay.mem", payload); $readmemh("vec/rxq_ev.mem", ev); end
      else begin $readmemh("vec/rxm_in.mem", samples); $readmemh("vec/rxm_pay.mem", payload); $readmemh("vec/rxm_ev.mem", ev); end
    end else begin
      $readmemh("vec/rxs_in.mem", samples); $readmemh("vec/rxs_pay.mem", payload); $readmemh("vec/rxs_ev.mem", ev);
    end
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    for (int n = 0; n < NS; n++) begin
      @(posedge clk); #1; in_valid = 1; in_i = samples[n][31:16]; in_q = samples[n][15:0];
      @(posedge clk); #1; in_valid = 0;
    end
    repeat (120000) begin
      @(posedge clk);
      if (npkt == NPKT) break;
    end
    repeat (400) @(posedge clk);

    if (npkt !== NPKT) begin errors++; $display("packets %0d != %0d", npkt, NPKT); end
    for (int p = 0; p < NPKT; p++) begin
      if (p < npkt) begin
        logic [63:0] h0; int pbytes, poff;
        h0 = pk[p][0];
        pbytes = (p == 0) ? PB0 : PB1; poff = (p == 0) ? 0 : PB0;
        if (pk_len[p] !== ((p == 0) ? NBEATS0 : NBEATS1)) begin errors++; $display("pkt %0d: %0d beats (exp %0d)", p, pk_len[p], (p == 0) ? NBEATS0 : NBEATS1); end
        if (h0[63:48] !== 16'hA55A || h0[47:40] !== (CODED ? 8'h03 : 8'h02)) begin errors++; $display("pkt %0d: bad magic/version %016x", p, h0); end
        if (h0[31:16] !== pbytes) begin errors++; $display("pkt %0d: nbytes %0d", p, h0[31:16]); end
        if (h0[15:0] !== p) begin errors++; $display("pkt %0d: seq %0d", p, h0[15:0]); end
        if (h0[39:32] !== 8'h00) begin errors++; $display("pkt %0d: flags %02x", p, h0[39:32]); end
        if (pk[p][1] !== {ev[4 * p + 1], ev[4 * p]}) begin
          errors++; $display("pkt %0d: {cfo_inc,n_best} got %08x/%08x exp %08x/%08x", p, pk[p][1][63:32], pk[p][1][31:0], ev[4 * p + 1], ev[4 * p]);
        end
        if (pk[p][2][47:32] !== ev[4 * p + 2][15:0]) begin errors++; $display("pkt %0d: rssi code got %04x exp %04x", p, pk[p][2][47:32], ev[4 * p + 2][15:0]); end
        if (!CODED && (pk[p][2][31:0] > ev[4 * p + 3] + ev[4 * p + 3] / 8 || pk[p][2][31:0] + ev[4 * p + 3] / 8 < ev[4 * p + 3] || ev[4 * p + 3] == 0))
          begin errors++; $display("pkt %0d: evm got %0d exp ~%0d", p, pk[p][2][31:0], ev[4 * p + 3]); end
        for (int b = 0; b < pbytes; b++) begin
          logic [7:0] got;
          got = pk[p][NH + b / 8][8 * (b % 8) +: 8];
          if (got !== payload[poff + b]) begin byte_errs++; if (byte_errs < 8) $display("byte err pkt %0d idx %0d got %02x exp %02x", p, b, got, payload[poff + b]); end
        end
      end
    end
    if (CODED) begin
      for (int p = 0; p < NPKT; p++) begin
        logic [63:0] b3, b4;
        b3 = pk[p][3]; b4 = pk[p][4];
        $display("pkt %0d: snr_avg %0d (%.1f dB) snr_min %0d bad %0d noise_code %0d | ldpc fail %0d iter_max %0d iter_sum %0d", p, $signed(b3[63:48]), $signed(b3[63:48]) * 0.0941, $signed(b3[47:32]), b3[31:16], $signed(b3[15:0]), b4[63:56], b4[52:48], b4[43:32]);
        if (b4[63:56] !== 8'd0) begin errors++; $display("pkt %0d: LDPC failures %0d", p, b4[63:56]); end
        if (b4[23:20] !== {1'b0, 1'b1, (p == 0) ? PM0 : PM1, 1'b1}) begin errors++; $display("pkt %0d: header bits {mism,ok,mode,dual} %04b", p, b4[23:20]); end
        if ($signed(b3[63:48]) <= 0) begin errors++; $display("pkt %0d: snr_avg code not positive", p); end
      end
    end
    if (byte_errs != 0) begin errors++; $display("payload byte errors: %0d of %0d", byte_errs, PB0 + PB1); end
    if (st_det_count !== NPKT || st_pkt_count !== NPKT || st_drop_count !== 0 || st_wd_count !== 0) begin
      errors++; $display("status det=%0d pkt=%0d drop=%0d wd=%0d", st_det_count, st_pkt_count, st_drop_count, st_wd_count);
    end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_top CODED=%0d MODE=%0d (2 packets, %0d + %0d bytes recovered, %0d samples)", CODED, MODE, PB0, PB1, NS);
    else $display("TEST FAILED tb_phy_rx_top errors=%0d", errors);
    $finish;
  end
endmodule
