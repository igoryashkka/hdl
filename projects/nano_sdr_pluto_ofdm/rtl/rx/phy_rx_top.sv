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
  parameter int WATCHDOG_BITS = 24,
  parameter int FFT_MASK      = 32'h00F,
  parameter int DC_K          = 12            // DC canceller time constant 2^K samples (K=10 hurts bin 1 next to DC)
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic [7:0]             cfg_nsyms,
  input  logic [31:0]            cfg_rmin,
  input  logic signed [3:0]      cfg_gain_sh,
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
  output logic                   st_busy
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
  logic signed [39:0] ev_p_re, ev_p_im;
  phy_sync_sc u_sync (
    .clk, .rst, .in_valid(dv), .in_i(di), .in_q(dq), .rmin(cfg_rmin), .rearm,
    .ev_valid, .ev_n_decl, .ev_n_best, .ev_p_re, .ev_p_im, .det_done
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
  phy_rx_window u_win (
    .clk, .rst, .arm_valid, .arm_w0, .arm_nwin, .in_valid(mx_valid), .in_i(mx_i), .in_q(mx_q),
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

  logic ce_done; logic [10:0] eq_addr; logic [39:0] w_data;
  phy_channel_estimator u_chest (
    .clk, .rst(rst | be_rst), .in_valid(bs_valid & lts_q), .in_first(bs_first), .in_last(bs_last), .in_re(bs_re), .in_im(bs_im),
    .done(ce_done), .rd_en(1'b1), .rd_addr(eq_addr), .rd_data(w_data)
  );

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
  phy_phase_tracker u_trk (
    .clk, .rst(rst | be_rst), .in_valid(eq_valid), .in_first(eq_first), .in_last(eq_last), .in_re(eq_re), .in_im(eq_im),
    .out_valid(pt_valid), .out_first(pt_first), .out_last(pt_last), .out_re(pt_re), .out_im(pt_im),
    .angle_o(pt_angle), .angle_valid(pt_angle_valid), .busy(pt_busy), .overrun(pt_overrun)
  );
  always_ff @(posedge clk) begin
    if (rst) last_angle <= '0; else if (pt_angle_valid) last_angle <= pt_angle;
  end

  logic dc_valid, dc_first, dc_last, il_ovf; logic [7:0] dc_data;
  phy_rx_decode u_dec (
    .clk, .rst(rst | be_rst), .nsyms(cfg_nsyms), .in_valid(pt_valid), .in_first(pt_first), .in_last(pt_last), .in_re(pt_re), .in_im(pt_im),
    .out_valid(dc_valid), .out_first(dc_first), .out_last(dc_last), .out_data(dc_data), .il_overflow(il_ovf)
  );

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
  wire  [15:0] nbytes_total = 16'(cfg_nsyms) * 16'(BYTES_PER_OFDM);
  phy_rx_pkt_out #(.RAM_BYTES(MAX_SYMS * BYTES_PER_OFDM)) u_pkt (
    .clk, .rst, .wr_en(dc_valid), .wr_addr(wr_addr_cur), .wr_data(dc_data),
    .commit(dc_valid & dc_last), .c_nbytes(nbytes_total), .c_flags(flags_q), .c_cfo_inc(nco_inc), .c_nbest(nbest_q), .c_angle(last_angle),
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

  assign flags_q = {4'b0, late_seen, fft_overflow, pt_overrun, il_ovf};
  assign st_flags = flags_q;
  assign st_busy  = (cst != C_IDLE);
  assign st_pkt_count  = po_cnt;
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
            nbest_q <= ev_n_best; w0_q <= ev_n_best + 32'(W0_OFFSET); nwin_q <= cfg_nsyms + 8'd1;
            late_seen <= 1'b0;
            cfo_start <= 1'b1; cst <= C_CFO;
          end
        end
        C_CFO: if (cfo_done) begin
          nco_inc <= cfo_inc; ph_clr <= 1'b1;
          arm_valid <= 1'b1; arm_w0 <= w0_q; arm_nwin <= nwin_q;
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
