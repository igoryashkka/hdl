// Module : phy_rx_top   OFDM PHY receiver (uncoded mode): AD9361 IQ -> decoded packets on a 64-bit AXI-stream (axi_dmac).
//   in -> phy_input_scale -> phy_dc_remove -> phy_sync_sc (detector) ........... ev: n_best, P
//                                          -> phy_nco_mixer (CFO derotation, inc = phy_cfo_coarse(P)) -> phy_rx_window
//   -> phy_rx_fft (FFT + reorder) -> phy_bin_select -> phy_channel_estimator (LTS frame) / phy_equalizer (data frames)
//   -> phy_phase_tracker -> phy_rx_decode -> byte buffer -> phy_rx_pkt_out (header + payload beats).
// Timing / architecture (see STATUS.md "RX"): the FFT window of the LTS starts at n_best + RX_W0_OFFSET samples (coarse
// timing only, window inside the CP), then every SYMBOL_LEN samples; cfg_nsyms data symbols follow the LTS.
// Control: one packet at a time. After the detector fires the controller computes the NCO increment (CORDIC), arms the window
// controller, waits until all frames are in the frame buffer, soft-resets the FFT core, waits for the last decoded byte and
// for the packet to leave the output buffer, then re-arms the detector. A watchdog re-arms everything if a packet stalls.
// Configuration inputs are static while a packet is in flight (cfg_nsyms 1..MAX_SYMS).
module phy_rx_top
  import phy_pkg::*;
#(
  parameter int MAX_SYMS      = 8,
  parameter int W0_OFFSET     = 104,
  parameter int WIN_DELAY     = 48,        // samples the window input lags the detector (arm latency margin: n_decl - n_best can reach TRACK_LEN)
  parameter int WATCHDOG_BITS = 24,
  parameter int FFT_MASK      = 32'h00F,
  parameter int DC_K          = 16,           // DC canceller time constant 2^K samples (K=12 left a 1-bit error at the band edge for CFO > 6 kHz, see phy_sim study)
  parameter bit CODED         = 1'b0          // 1: LDPC R=5/6 + soft LLR + MMSE post engine (450 bytes / symbol), 0: uncoded hard decision (550)
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic [7:0]             cfg_nsyms,
  input  logic [31:0]            cfg_rmin,
  input  logic signed [3:0]      cfg_gain_sh,
  input  logic                   cfg_mmse,         // coded mode: 1 = MMSE, 0 = ZF
  input  logic [4:0]             cfg_max_iter,     // coded mode: LDPC iteration limit
  input  logic signed [12:0]     cfg_bad_thr,      // bad-subcarrier threshold (SNR code, 106 = 10 dB)
  input  logic                   cfg_ft_en,        // fine timing loop: shift the next packet's FFT window by the measured LTS timing error
  input  logic [7:0]             cfg_tau_tgt,      // wanted LTS window earliness [samples] (nominal calibration: ~54)
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_i,
  input  logic signed [IQ_W-1:0] in_q,
  output logic                   m_axis_valid,
  input  logic                   m_axis_ready,
  output logic [63:0]            m_axis_data,
  output logic                   m_axis_last,
  output logic [15:0]            st_det_count,
  output logic [15:0]            st_pkt_count,
  output logic [15:0]            st_drop_count,
  output logic [15:0]            st_wd_count,
  output logic [7:0]             st_flags,
  output logic                   st_busy,
  output logic [15:0]            st_rssi,         // last packet: header fields (valid after the first packet)
  output logic [31:0]            st_evm,
  output logic [31:0]            st_cfo_inc,
  output logic [31:0]            st_nbest,
  output logic [15:0]            st_angle,
  output logic [15:0]            st_seq,
  output logic                   st_pkt_pulse,    // one clk pulse when a packet record is committed
  output logic [15:0]            st_snr_avg,      // last packet: channel quality codes (log2 * 32), coded mode only
  output logic [15:0]            st_snr_min,
  output logic [15:0]            st_bad,
  output logic [15:0]            st_noise,
  output logic [7:0]             st_ldpc_fail,
  output logic [4:0]             st_ldpc_imax,
  output logic [11:0]            st_ldpc_isum,
  output logic [15:0]            st_cw_count,     // decoded codewords / non-converged codewords since reset
  output logic [15:0]            st_cwfail_count,
  output logic signed [19:0]     st_tau_q8,       // fine timing of the last packet (1/256 sample, positive = window early)
  output logic signed [7:0]      st_w0_adj        // current window correction [samples]
);
  // ===================================================================== front end
  logic sv_i, sv_q; logic signed [IQ_W-1:0] si, sq;
  phy_input_scale #(.W(IQ_W)) u_sc_i (.clk, .rst, .sh(cfg_gain_sh), .in_valid, .in_data(in_i), .out_valid(sv_i), .out_data(si));
  phy_input_scale #(.W(IQ_W)) u_sc_q (.clk, .rst, .sh(cfg_gain_sh), .in_valid, .in_data(in_q), .out_valid(sv_q), .out_data(sq));
  logic dv_i, dv_q; logic signed [IQ_W-1:0] di, dq;
  phy_dc_remove #(.W(IQ_W), .K(DC_K)) u_dc_i (.clk, .rst, .in_valid(sv_i), .in_data(si), .out_valid(dv_i), .out_data(di));
  phy_dc_remove #(.W(IQ_W), .K(DC_K)) u_dc_q (.clk, .rst, .in_valid(sv_q), .in_data(sq), .out_valid(dv_q), .out_data(dq));
  wire dv = dv_i;

  // ===================================================================== detector
  logic        rearm;
  logic        ev_valid, det_done;
  logic [31:0] ev_n_decl, ev_n_best;
  logic [39:0] ev_r;
  logic signed [39:0] ev_p_re, ev_p_im;
  phy_sync_sc u_sync (
    .clk, .rst, .in_valid(dv), .in_i(di), .in_q(dq), .rmin(cfg_rmin), .rearm,
    .ev_valid, .ev_n_decl, .ev_n_best, .ev_p_re, .ev_p_im, .ev_r, .det_done
  );

  logic        cfo_start, cfo_busy, cfo_done;
  logic [31:0] cfo_inc;
  phy_cfo_coarse u_cfo (.clk, .rst, .start(cfo_start), .p_re(ev_p_re), .p_im(ev_p_im), .busy(cfo_busy), .done(cfo_done), .inc(cfo_inc));

  // ===================================================================== mixer + window
  logic [31:0] nco_inc;
  logic        ph_clr;
  logic        mx_valid; logic signed [IQ_W-1:0] mx_i, mx_q;
  phy_nco_mixer #(.W(IQ_W)) u_mix (
    .clk, .rst, .inc(nco_inc), .ph_clr, .in_valid(dv), .in_i(di), .in_q(dq), .out_valid(mx_valid), .out_i(mx_i), .out_q(mx_q)
  );

  logic        arm_valid;
  logic [31:0] arm_w0;
  logic [7:0]  arm_nwin;
  logic        w_valid, w_first, w_last, w_busy, w_late, w_done;
  logic signed [IQ_W-1:0] w_i, w_q;
  logic [7:0]  w_win;
  // The detector declares up to TRACK_LEN samples after n_best and the CFO measurement adds more, so the window start (n_best + W0_OFFSET)
  // can already lie in the past when armed. The window sees the (mixed) stream WIN_DELAY samples late; the sample index is unchanged
  // (the delay line advances on valid samples only, so index n of the window input equals the detector index).
  logic signed [IQ_W-1:0] dl_i [WIN_DELAY], dl_q [WIN_DELAY];
  always_ff @(posedge clk) if (mx_valid) begin
    dl_i[0] <= mx_i; dl_q[0] <= mx_q;
    for (int k = 1; k < WIN_DELAY; k++) begin dl_i[k] <= dl_i[k-1]; dl_q[k] <= dl_q[k-1]; end
  end
  phy_rx_window u_win (
    .clk, .rst, .arm_valid, .arm_w0, .arm_nwin, .in_valid(mx_valid), .in_i(dl_i[WIN_DELAY-1]), .in_q(dl_q[WIN_DELAY-1]),
    .out_valid(w_valid), .out_i(w_i), .out_q(w_q), .out_first(w_first), .out_last(w_last), .out_win(w_win),
    .busy(w_busy), .late(w_late), .done(w_done)
  );

  // ===================================================================== FFT + frame buffer
  logic core_rst, frame_written, fft_overflow;
  logic f_valid, f_first, f_last, f_done;
  logic signed [IQ_W-1:0] f_re, f_im;
  phy_rx_fft #(.SHIFT_MASK(FFT_MASK), .NB(2)) u_fft (
    .clk, .rst, .core_rst, .in_valid(w_valid), .in_re(w_i), .in_im(w_q),
    .frame_written, .overflow(fft_overflow),
    .out_valid(f_valid), .out_ready(1'b1), .out_re(f_re), .out_im(f_im), .out_first(f_first), .out_last(f_last), .frame_done(f_done)
  );

  // frame type: first frame after arm = LTS
  logic [7:0] frame_cnt;
  logic       lts_q;
  wire        lts_cur = f_first ? (frame_cnt == 8'd0) : lts_q;
  logic       be_rst;                       // soft reset of the back-end (watchdog)
  always_ff @(posedge clk) begin
    if (rst || arm_valid) begin frame_cnt <= '0; lts_q <= 1'b1; end
    else if (f_valid && f_first) begin frame_cnt <= frame_cnt + 1'b1; lts_q <= (frame_cnt == 8'd0); end
  end

  logic bs_valid, bs_first, bs_last, bs_pilot;
  logic signed [IQ_W-1:0] bs_re, bs_im;
  phy_bin_select u_bsel (
    .clk, .rst(rst | be_rst), .in_valid(f_valid), .in_first(f_first), .in_re(f_re), .in_im(f_im),
    .out_valid(bs_valid), .out_first(bs_first), .out_last(bs_last), .out_pilot(bs_pilot), .out_re(bs_re), .out_im(bs_im)
  );

  logic ce_done; logic [10:0] eq_addr; logic [39:0] w_data; logic tau_valid; logic signed [19:0] tau_q8;
  logic [10:0] eg_ra, eg_wa; logic [39:0] eg_rw, eg_wd; logic signed [11:0] eg_rlg; logic eg_we; logic [41:0] sig_sum;
  phy_channel_estimator u_chest (
    .clk, .rst(rst | be_rst), .in_valid(bs_valid & lts_q), .in_first(bs_first), .in_last(bs_last), .in_re(bs_re), .in_im(bs_im),
    .done(ce_done), .rd_en(1'b1), .rd_addr(eq_addr), .rd_data(w_data),
    .eng_ra(eg_ra), .eng_rw(eg_rw), .eng_rlg(eg_rlg), .eng_we(eg_we), .eng_wa(eg_wa), .eng_wd(eg_wd), .sig_sum(sig_sum),
    .tau_valid, .tau_q8
  );

  // coded mode: noise estimate (guard bins of the LTS FFT frame) + MMSE post engine (weights, LLR parameters, channel quality)
  logic [10:0] prm_ra; logic [28:0] prm_rd; logic prm_ready;
  logic q_valid; logic signed [12:0] q_avg, q_min, nu_code; logic [10:0] q_bad;
  if (CODED) begin : g_soft
    logic nu_valid; logic signed [12:0] lg_nu; logic [40:0] nse_sum;
    phy_noise_est u_nse (
      .clk, .rst(rst | be_rst), .en(lts_cur), .in_valid(f_valid), .in_first(f_first), .in_re(f_re), .in_im(f_im),
      .nu_valid, .lg_nu, .noise_sum(nse_sum)
    );
    logic busy_unused;
    phy_mmse_post u_post (
      .clk, .rst(rst | be_rst), .clr(arm_valid), .cfg_mmse, .chest_done(ce_done), .nu_valid, .lg_nu,
      .eng_ra(eg_ra), .eng_rw(eg_rw), .eng_rlg(eg_rlg), .eng_we(eg_we), .eng_wa(eg_wa), .eng_wd(eg_wd),
      .prm_ra, .prm_rd, .ready(prm_ready), .busy(busy_unused),
      .sig_sum, .cfg_bad_thr, .q_valid, .q_snr_avg(q_avg), .q_snr_min(q_min), .q_bad
    );
    always_ff @(posedge clk) if (nu_valid) nu_code <= lg_nu;
  end else begin : g_nosoft
    assign eg_ra = '0; assign eg_we = 1'b0; assign eg_wa = '0; assign eg_wd = '0;
    assign prm_rd = '0; assign prm_ready = 1'b1; assign q_valid = 1'b0; assign q_avg = '0; assign q_min = '0; assign q_bad = '0;
    assign nu_code = '0;
  end

  logic eq_valid, eq_first, eq_last;
  logic signed [IQ_W-1:0] eq_re, eq_im;
  phy_equalizer u_eq (
    .clk, .rst(rst | be_rst), .in_valid(bs_valid & ~lts_q), .in_first(bs_first), .in_last(bs_last), .in_re(bs_re), .in_im(bs_im),
    .rd_addr(eq_addr), .rd_data(w_data),
    .out_valid(eq_valid), .out_first(eq_first), .out_last(eq_last), .out_re(eq_re), .out_im(eq_im)
  );

  logic pt_valid, pt_first, pt_last, pt_angle_valid, pt_busy, pt_overrun;
  logic signed [IQ_W-1:0] pt_re, pt_im;
  logic [31:0] pt_angle, last_angle;
  logic pt_l1_valid; logic [23:0] pt_l1;
  logic [31:0] pt_slope; logic pt_slope_valid;
  phy_phase_tracker #(.SLOPE(CODED)) u_trk (
    .clk, .rst(rst | be_rst), .in_valid(eq_valid), .in_first(eq_first), .in_last(eq_last), .in_re(eq_re), .in_im(eq_im),
    .out_valid(pt_valid), .out_first(pt_first), .out_last(pt_last), .out_re(pt_re), .out_im(pt_im),
    .angle_o(pt_angle), .angle_valid(pt_angle_valid), .busy(pt_busy), .overrun(pt_overrun),
    .l1_valid(pt_l1_valid), .l1_val(pt_l1), .slope_o(pt_slope), .slope_valid(pt_slope_valid)
  );
  always_ff @(posedge clk) begin
    if (rst) last_angle <= '0; else if (pt_angle_valid) last_angle <= pt_angle;
  end

  // packet EVM proxy: sum of the per-symbol pilot L1 errors, cleared when the window controller is armed
  logic [31:0] evm_acc;
  always_ff @(posedge clk) begin
    if (rst || arm_valid) evm_acc <= '0;
    else if (pt_l1_valid) evm_acc <= evm_acc + 32'(pt_l1);
  end
  // RSSI: log code of the detector window energy at the timing peak, latched at the detection event
  logic        rs_v; logic [15:0] rs_code, rssi_q;
  phy_rssi_code u_rssi (.clk, .rst, .in_valid(ev_valid), .in_r(ev_r), .out_valid(rs_v), .code(rs_code));
  always_ff @(posedge clk) begin
    if (rst) rssi_q <= '0; else if (rs_v) rssi_q <= rs_code;
  end

  logic dc_valid, dc_first, dc_last, il_ovf; logic [7:0] dc_data;
  logic ld_stat_valid, cw_pulse, cw_fail_pulse; logic [7:0] ld_fail; logic [4:0] ld_imax; logic [11:0] ld_isum;
  if (CODED) begin : g_dec_ldpc
    phy_rx_decode_ldpc u_dec (
      .clk, .rst(rst | be_rst), .nsyms(cfg_nsyms), .cfg_max_iter, .in_valid(pt_valid), .in_first(pt_first), .in_last(pt_last),
      .in_re(pt_re), .in_im(pt_im), .prm_ra, .prm_rd,
      .out_valid(dc_valid), .out_first(dc_first), .out_last(dc_last), .out_data(dc_data), .il_overflow(il_ovf),
      .stat_valid(ld_stat_valid), .stat_fail(ld_fail), .stat_iter_max(ld_imax), .stat_iter_sum(ld_isum),
      .cw_pulse, .cw_fail_pulse
    );
  end else begin : g_dec_hard
    phy_rx_decode u_dec (
      .clk, .rst(rst | be_rst), .nsyms(cfg_nsyms), .in_valid(pt_valid), .in_first(pt_first), .in_last(pt_last), .in_re(pt_re), .in_im(pt_im),
      .out_valid(dc_valid), .out_first(dc_first), .out_last(dc_last), .out_data(dc_data), .il_overflow(il_ovf)
    );
    assign prm_ra = '0; assign ld_stat_valid = 1'b0; assign ld_fail = '0; assign ld_imax = '0; assign ld_isum = '0;
    assign cw_pulse = 1'b0; assign cw_fail_pulse = 1'b0;
  end

  // residual CFO / SFO observables of the packet: CPE angle of the first data symbol and phase slope of the last one
  logic [31:0] angle_first, slope_last; logic first_sym;
  always_ff @(posedge clk) begin
    if (rst || arm_valid) begin first_sym <= 1'b1; angle_first <= '0; slope_last <= '0; end
    else begin
      if (pt_angle_valid && first_sym) begin angle_first <= pt_angle; first_sym <= 1'b0; end
      if (pt_slope_valid) slope_last <= pt_slope;
    end
  end

  // quality / LDPC statistics of the last packet (held until the next one)
  logic prm_late;
  logic [7:0] fail_l; logic [4:0] imax_l; logic [11:0] isum_l;
  always_ff @(posedge clk) begin
    if (rst) begin
      st_snr_avg <= '0; st_snr_min <= '0; st_bad <= '0; st_noise <= '0; fail_l <= '0; imax_l <= '0; isum_l <= '0;
      st_cw_count <= '0; st_cwfail_count <= '0; prm_late <= 1'b0;
    end else begin
      if (arm_valid) prm_late <= 1'b0;
      else if (pt_valid && pt_first && !prm_ready) prm_late <= 1'b1;
      if (q_valid) begin st_snr_avg <= 16'(q_avg); st_snr_min <= 16'(q_min); st_bad <= 16'(q_bad); st_noise <= 16'(nu_code); end
      if (ld_stat_valid) begin fail_l <= ld_fail; imax_l <= ld_imax; isum_l <= ld_isum; end
      if (cw_pulse) st_cw_count <= st_cw_count + 1'b1;
      if (cw_fail_pulse) st_cwfail_count <= st_cwfail_count + 1'b1;
    end
  end
  assign st_ldpc_fail = fail_l; assign st_ldpc_imax = imax_l; assign st_ldpc_isum = isum_l;

  // ===================================================================== byte buffer + packet output
  logic [12:0] wr_addr;
  always_ff @(posedge clk) begin
    if (rst || be_rst) wr_addr <= '0;
    else if (dc_valid) wr_addr <= dc_first ? 13'd1 : wr_addr + 1'b1;
  end
  wire [12:0] wr_addr_cur = dc_first ? 13'd0 : wr_addr;

  logic [31:0] nbest_q, w0_q;
  logic        commit, po_busy;
  logic [15:0] po_drop, po_cnt;
  logic [7:0]  flags_q;
  logic        late_seen;
  wire  [15:0] nbytes_total = 16'(cfg_nsyms) * 16'(CODED ? 450 : BYTES_PER_OFDM);
  wire [63:0] hdr_b3 = {st_snr_avg, st_snr_min, st_bad, st_noise};
  wire [63:0] hdr_b5 = {angle_first, slope_last};
  wire [63:0] hdr_b4 = {fail_l, 3'b0, imax_l, 4'b0, isum_l, 6'b0, cfg_mmse, CODED, 4'd0, st_tau_q8};
  phy_rx_pkt_out #(.RAM_BYTES(MAX_SYMS * BYTES_PER_OFDM), .HDR_V3(CODED)) u_pkt (
    .clk, .rst, .wr_en(dc_valid), .wr_addr(wr_addr_cur), .wr_data(dc_data),
    .commit(dc_valid & dc_last), .c_nbytes(nbytes_total), .c_flags(flags_q), .c_cfo_inc(nco_inc), .c_nbest(nbest_q), .c_angle(last_angle), .c_rssi(rssi_q), .c_evm(evm_acc), .c_b3(hdr_b3), .c_b4(hdr_b4), .c_b5(hdr_b5),
    .busy(po_busy), .dropped(po_drop), .pkt_count(po_cnt),
    .m_axis_valid, .m_axis_ready, .m_axis_data, .m_axis_last
  );

  // ===================================================================== controller
  typedef enum logic [2:0] {C_IDLE, C_CFO, C_RUN, C_DECODE, C_FIN} cst_t;
  cst_t cst;
  logic [7:0]  nwin_q, fw_cnt;
  logic        dec_done;
  logic [WATCHDOG_BITS-1:0] wd;
  logic [2:0]  rst_cnt;
  logic        wd_hit;

  assign flags_q = {2'b0, (fail_l != 8'd0), prm_late, late_seen, fft_overflow, pt_overrun, il_ovf};
  // fine timing loop (coded mode): w0_adj += (tau - target) / 2 per packet, clamped to +-40 samples
  logic signed [7:0] w0_adj;
  wire  signed [20:0] tau_err = 21'(tau_q8) - $signed({1'b0, cfg_tau_tgt, 8'd0});
  logic signed [12:0] adj_step; logic tau_valid_q;          // step registered one cycle (timing)
  always_ff @(posedge clk) begin adj_step <= 13'(tau_err >>> 9); tau_valid_q <= tau_valid & ~rst; end
  wire  signed [12:0] adj_nxt  = 13'(w0_adj) + adj_step;
  always_ff @(posedge clk) begin
    if (rst) w0_adj <= '0;
    else if (!cfg_ft_en) w0_adj <= '0;
    else if (tau_valid_q && CODED) w0_adj <= (adj_nxt > 13'sd40) ? 8'sd40 : (adj_nxt < -13'sd40) ? -8'sd40 : adj_nxt[7:0];
  end
  assign st_w0_adj = w0_adj;
  always_ff @(posedge clk) begin
    if (rst) st_tau_q8 <= '0; else if (tau_valid) st_tau_q8 <= tau_q8;
  end
  assign st_flags = flags_q;
  assign st_busy  = (cst != C_IDLE);
  assign st_pkt_count  = po_cnt;
  assign st_pkt_pulse  = dc_valid & dc_last;
  always_ff @(posedge clk) begin
    if (rst) begin st_rssi <= '0; st_evm <= '0; st_cfo_inc <= '0; st_nbest <= '0; st_angle <= '0; st_seq <= '0; end
    else if (dc_valid && dc_last) begin
      st_rssi <= rssi_q; st_evm <= evm_acc; st_cfo_inc <= nco_inc; st_nbest <= nbest_q; st_angle <= last_angle[31:16]; st_seq <= po_cnt;
    end
  end
  assign st_drop_count = po_drop;

  always_ff @(posedge clk) begin
    cfo_start <= 1'b0; ph_clr <= 1'b0; arm_valid <= 1'b0; rearm <= 1'b0; core_rst <= 1'b0; be_rst <= 1'b0;
    if (rst) begin
      cst <= C_IDLE; nbest_q <= '0; w0_q <= '0; nwin_q <= '0; fw_cnt <= '0; dec_done <= 1'b0; wd <= '0; nco_inc <= '0;
      st_det_count <= '0; st_wd_count <= '0; late_seen <= 1'b0; arm_w0 <= '0; arm_nwin <= '0; rst_cnt <= '0;
    end else begin
      if (cst != C_IDLE) wd <= wd + 1'b1; else wd <= '0;
      if (w_late) late_seen <= 1'b1;
      if (frame_written) fw_cnt <= fw_cnt + 1'b1;
      if (dc_valid && dc_last) dec_done <= 1'b1;
      case (cst)
        C_IDLE: begin
          fw_cnt <= '0; dec_done <= 1'b0;
          if (ev_valid) begin
            st_det_count <= st_det_count + 1'b1;
            nbest_q <= ev_n_best; w0_q <= ev_n_best + 32'(W0_OFFSET) + 32'($signed(w0_adj)); nwin_q <= cfg_nsyms + 8'd1;
            late_seen <= 1'b0;
            cfo_start <= 1'b1; cst <= C_CFO;
          end
        end
        C_CFO: if (cfo_done) begin
          nco_inc <= cfo_inc; ph_clr <= 1'b1;
          arm_valid <= 1'b1; arm_w0 <= w0_q + 32'(WIN_DELAY); arm_nwin <= nwin_q;
          cst <= C_RUN;
        end
        C_RUN: begin
          if (w_late) begin cst <= C_FIN; rst_cnt <= '0; end                  // arm refused: clean up and re-arm
          else if (fw_cnt == nwin_q) begin core_rst <= 1'b1; cst <= C_DECODE; end
        end
        C_DECODE: if (dec_done && !po_busy) begin cst <= C_FIN; rst_cnt <= '0; end
        C_FIN: begin
          rst_cnt <= rst_cnt + 1'b1;
          if (rst_cnt == 3'd1) core_rst <= 1'b1;
          if (rst_cnt == 3'd3) begin rearm <= 1'b1; cst <= C_IDLE; end
        end
        default: cst <= C_IDLE;
      endcase
      if (cst != C_IDLE && wd == '1) begin           // watchdog: packet stalled
        st_wd_count <= st_wd_count + 1'b1; be_rst <= 1'b1; core_rst <= 1'b1; rst_cnt <= '0; cst <= C_FIN;
      end
    end
  end
endmodule
