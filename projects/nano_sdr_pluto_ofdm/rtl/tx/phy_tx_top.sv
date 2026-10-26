// Module : phy_tx_top   OFDM PHY transmitter, uncoded legacy mode (CODED = 0) or dual-mode coded PHY (CODED = 1, cfg_mode):
//   cfg_mode = 0 MAX RANGE: QPSK + LDPC 1/2 (135 payload bytes per OFDM symbol)   cfg_mode = 1 MAX RATE: 16-QAM + LDPC 5/6 (450 bytes).
//   Coded frame = [sync][LTS][header symbol][data symbols]; the header symbol (phy_hdr_gen, QPSK, repetition coded) carries MODE_ID and nsyms.
//   cfg_mode is sampled with the first byte of a packet and must be static until the packet is complete (switch only between packets).
//   bytes -> packet buffer -> scrambler -> nibbles -> interleaver -> QAM mapper -> OFDM mapper -> pilot insert
//   -> (mux with preamble) -> IFFT -> digital scaler -> bit-reverse + cyclic prefix buffer -> IQ (pulled at sample rate)
// Packet: s_valid/s_ready/s_data/s_last; payload is padded with zeros to a multiple of BYTES_PER_OFDM (550) bytes
//   (one OFDM symbol). Max TX_MAX_SYMS symbols (4400 bytes); longer packets are truncated (pkt_trunc flag).
// Output: iq_pull (sample strobe from the DAC interface) -> iq_re/iq_im valid the same cycle (0 when nothing to send).
//   `underflow` pulses when a sample was pulled during an active packet but none was ready (should never happen).
// Timing contract: after a packet is complete, the first sample is available after ~2 symbol compute times; samples of one
//   frame are then continuous at the pull rate (credit logic in phy_tx_frame_ctrl guarantees banks are filled in time as
//   long as the processing clock is >= 2x the sample rate).
// CONT = 1 at runtime (input `cont`, CODED = 1 only): continuous / streaming frame. The packet buffer becomes a ring: the packet
//   starts after 64 bytes are buffered, the writer is back-pressured when the ring is full, the reader waits for data. The frame
//   length (symbols) comes from `cont_nb` (bytes, known from the DMA header) instead of from the end of the write, so one frame can
//   carry up to 255 symbols (65535 bytes) with the same [sync][LTS][header] overhead. `cont` is sampled with the first byte.
// BF = 1 (beamforming, TestTask006): two output channels sharing everything up to the IFFT input mux; per channel
//   phy_tx_weight (mode/amp/phase/tau latched at the packet start, go_fire) -> IFFT -> scaler -> CP buffer. Both channels run
//   in lock-step (same latency), channel 0 drives the frame control. go_en gates the packet start (timed launch).
// Golden: python/tx_ref.py::tx_frame (whole chain, bit-exact incl. fixed-point IFFT, scaling and CP);
//   BF = 1: python/bf_ref.py::tx_frame_bf.
module phy_tx_top
  import phy_pkg::*;
#(
  parameter int MAX_SYMS   = TX_MAX_SYMS,
  parameter int SHIFT_MASK = 32'h0FF,
  parameter bit CODED      = 1'b0,           // 1: LDPC R=5/6 (450 payload bytes per OFDM symbol), 0: uncoded (550)
  parameter bit BF         = 1'b0            // 1: two weighted output channels (beamforming)
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic [15:0]            gain,           // Q2.14, 16384 = 1.0
  input  logic                   cfg_mode,       // coded PHY: 0 = MAX RANGE (QPSK, 1/2), 1 = MAX RATE (16-QAM, 5/6)
  input  logic                   cont,           // continuous / streaming frame (sampled with the first byte; CODED = 1)
  input  logic [15:0]            cont_nb,        // packet length in bytes (valid from before the first byte; used with `cont`)
  // packet bytes
  input  logic                   s_valid,
  output logic                   s_ready,
  input  logic [7:0]             s_data,
  input  logic                   s_last,
  // IQ out (pull)
  input  logic                   iq_pull,
  output logic signed [IQ_W-1:0] iq_re,
  output logic signed [IQ_W-1:0] iq_im,
  output logic                   iq_valid,
  // status
  output logic                   underflow,
  output logic                   overflow,
  output logic                   pkt_trunc,
  output logic                   pkt_done,
  output logic                   busy,
  // beamforming (BF = 1; ignored otherwise)
  input  logic                   go_en,          // packet start allowed (timed launch), 1 = immediately
  output logic                   go_fire,        // packet start pulse (weights are latched here)
  input  logic [3:0]             w_mode,         // {ch1, ch0}: 0 bypass, 1 weight, 2 mute
  input  logic [31:0]            w_amp,          // {ch1, ch0} Q1.15
  input  logic [31:0]            w_phase,        // {ch1, ch0} 2^16 = 2*pi
  input  logic [33:0]            w_tau,          // {ch1, ch0} signed 17 bit, 1/256 sample (> 0 advances)
  output logic signed [IQ_W-1:0] iq1_re,
  output logic signed [IQ_W-1:0] iq1_im
);
  localparam int BUF_BYTES = MAX_SYMS * BYTES_PER_OFDM;
  localparam int BAW       = $clog2(BUF_BYTES);

  // ===================================================================== packet buffer (receive side)
  logic [7:0]     bbuf [BUF_BYTES];
  logic [BAW-1:0] wr_ptr;
  localparam int CW = 17;                      // byte counters (65535-byte continuous frames)
  localparam int PREFILL = 64;                 // bytes buffered before a continuous frame starts
  logic [CW-1:0]  wr_cnt;                      // bytes written of the packet
  logic [BAW-1:0] rd_ptr;                      // ring read address
  logic           pkt_taken;                   // the frame controller took the packet (reader running)
  logic           cont_r, wr_fin;              // packet is continuous / all its bytes are written
  logic [CW-1:0]  pkt_len;                    // bytes stored
  logic [9:0]     sym_byte_cnt;
  logic [7:0]     nsyms_acc, pkt_nsyms;
  logic           wr_mode, pkt_mode;          // mode of the packet being written / of the packet being sent
  wire  [9:0]     bps_w = CODED ? (wr_mode ? 10'd450 : 10'd135) : 10'(BYTES_PER_OFDM);   // payload bytes per OFDM symbol
  wire            wr_first  = (wr_cnt == '0);
  wire            cont_en   = cont & CODED;
  wire            wr_mode_n = wr_first ? cfg_mode : wr_mode;                          // the first byte already counts with the new mode
  logic           pkt_valid;                  // a complete packet is waiting for / being sent
  logic           rd_busy;                    // reader is streaming the packet out of the buffer
  logic           go_ready;
  logic           rd_done;
  logic           tx_started_out;

  logic [CW-1:0]  rd_idx;
  wire            cont_w = wr_first ? cont_en : cont_r;
  wire            ring_full = cont_r && ((wr_cnt - rd_idx) >= CW'(BUF_BYTES));
  // continuous frame length in symbols = ceil(cont_nb / bytes per symbol): exact reciprocal multiplication (K = ceil(2^26 / bps),
  // checked for every input 0 .. 65535), 3 pipeline stages; cont_nb and cfg_mode are static for many cycles before the first byte
  logic [16:0]    nc_x;
  logic [19:0]    nc_k;
  logic [36:0]    nc_p;
  logic [7:0]     nsyms_c_r;
  logic [2:0]     cw_sh;                        // continuous frame: first byte seen >= 3 cycles ago (length valid)
  always_ff @(posedge clk) begin
    nc_x      <= 17'(cont_nb) + (cfg_mode ? 17'd449 : 17'd134);
    nc_k      <= cfg_mode ? 20'd149131 : 20'd497103;
    nc_p      <= nc_x * nc_k;
    nsyms_c_r <= nc_p[33:26];
    if (rst) cw_sh <= '0; else cw_sh <= {cw_sh[1:0], cont_r};
  end
  assign s_ready = !wr_fin && !(pkt_valid && !cont_r) && !ring_full;
  wire   wr_en   = s_valid & s_ready;
  wire   wr_end  = s_last | (!cont_w && (wr_ptr == BAW'(BUF_BYTES - 1)));

  always_ff @(posedge clk) begin
    if (wr_en) bbuf[wr_ptr] <= s_data;
    if (wr_en && wr_first) wr_mode <= cfg_mode;
    if (rst) begin
      wr_ptr <= '0; pkt_len <= '0; sym_byte_cnt <= '0; nsyms_acc <= '0; pkt_nsyms <= '0;
      pkt_valid <= 1'b0; pkt_trunc <= 1'b0; wr_mode <= 1'b1; wr_cnt <= '0; wr_fin <= 1'b0; cont_r <= 1'b0;
    end else begin
      if (wr_en) begin
        if (sym_byte_cnt == (CODED ? (wr_mode_n ? 10'd449 : 10'd134) : 10'(BYTES_PER_OFDM - 1))) begin sym_byte_cnt <= '0; nsyms_acc <= nsyms_acc + 1'b1; end
        else sym_byte_cnt <= sym_byte_cnt + 1'b1;
        wr_cnt <= wr_cnt + 1'b1;
        if (wr_first) begin
          cont_r <= cont_en;
          if (cont_en) pkt_len <= CW'(cont_nb);
        end
        if (wr_end) begin
          if (!cont_w) begin
            pkt_len   <= wr_cnt + 1'b1;
            pkt_nsyms <= nsyms_acc + 1'b1;
            pkt_trunc <= ~s_last;
          end else wr_fin <= 1'b1;
          pkt_valid <= 1'b1;
        end else begin
          wr_ptr <= (wr_ptr == BAW'(BUF_BYTES - 1)) ? '0 : wr_ptr + 1'b1;            // ring (only reached by continuous frames)
          if (cont_w && (wr_cnt + 1'b1 >= CW'(PREFILL))) pkt_valid <= 1'b1;
        end
      end
      if (cont_r && !cw_sh[2]) pkt_nsyms <= nsyms_c_r;   // continuous frame: length in symbols from the pipeline above (window of the first 3 cycles;
                                                         // cont_nb / cfg_mode must be stable from 3 cycles before the first byte until then)
      if (pkt_valid && !rd_busy && rd_done) begin       // buffer fully read out -> accept the next packet
        pkt_valid <= 1'b0; wr_ptr <= '0; wr_cnt <= '0; wr_fin <= 1'b0; cont_r <= 1'b0; sym_byte_cnt <= '0; nsyms_acc <= '0;
      end
    end
  end

  // ===================================================================== frame controller
  logic pre_start_valid, pre_start_ready, pre_start_kind, map_start_valid, map_start_ready;
  logic sym_end, flush_valid, frame_written, sym_done, fft_rst, ctrl_active;
  logic go_valid;

  // the reader starts together with the controller (go handshake); `started_pkt` marks the packet as taken
  assign go_valid = pkt_valid && !pkt_taken && (go_en || !BF) && (!cont_r || cw_sh[2]);

  phy_tx_frame_ctrl u_ctrl (
    .clk, .rst,
    .go_valid, .go_ready, .go_nsyms(pkt_nsyms + 8'(CODED)),
    .pre_start_valid, .pre_start_ready, .pre_start_kind,
    .map_start_valid, .map_start_ready,
    .sym_end, .flush_valid, .frame_written, .sym_done,
    .fft_rst, .pkt_done, .active(ctrl_active)
  );

  // ===================================================================== reader: buffer -> scrambler -> byte FIFO
  logic [CW-1:0] total_bytes;                 // padded length
  logic          a_v, a_first, a_last, a_pad;
  logic [7:0]    ram_q;
  logic          scr_v, scr_first, scr_last; logic [7:0] scr_d;
  logic          bf_wr_ready, bf_rd_valid, bf_rd_ready; logic [7:0] bf_rd_data; logic [3:0] bf_count;

  wire rd_have  = !cont_r || wr_fin || (rd_idx < wr_cnt);   // continuous frame: the byte must be written already (after the last byte: padding)
  wire rd_issue = rd_busy && (rd_idx != total_bytes) && rd_have && ((bf_count + 4'(a_v) + 4'(scr_v)) < 4'd6);

  always_ff @(posedge clk) begin
    ram_q <= bbuf[rd_ptr];
    rd_done <= 1'b0;
    if (rst) begin
      rd_busy <= 1'b0; rd_idx <= '0; rd_ptr <= '0; total_bytes <= '0; a_v <= 1'b0; pkt_taken <= 1'b0;
    end else begin
      if (go_valid && go_ready) begin
        pkt_taken   <= 1'b1;
        pkt_mode    <= wr_mode;
        rd_busy     <= 1'b1;
        rd_idx      <= '0;
        rd_ptr      <= '0;
        total_bytes <= CW'(pkt_nsyms) * (CODED ? (wr_mode ? CW'(450) : CW'(135)) : CW'(BYTES_PER_OFDM));
      end
      a_v <= rd_issue;
      if (rd_issue) begin
        a_first <= (rd_idx == '0);
        a_last  <= (rd_idx == total_bytes - 1'b1);
        a_pad   <= (rd_idx >= pkt_len);
        rd_idx  <= rd_idx + 1'b1;
        rd_ptr  <= (rd_ptr == BAW'(BUF_BYTES - 1)) ? '0 : rd_ptr + 1'b1;
      end
      if (rd_busy && rd_idx == total_bytes && !a_v && !scr_v) begin
        rd_busy <= 1'b0; rd_done <= 1'b1;
      end
      if (rd_done) begin pkt_taken <= 1'b0; rd_idx <= '0; rd_ptr <= '0; end
    end
  end

  phy_scrambler u_scr (
    .clk, .rst,
    .in_valid(a_v), .in_first(a_first), .in_last(a_last), .in_data(a_pad ? 8'h00 : ram_q),
    .out_valid(scr_v), .out_first(scr_first), .out_last(scr_last), .out_data(scr_d)
  );

  phy_fifo #(.W(8), .DEPTH(8)) u_bfifo (
    .clk, .rst, .wr_valid(scr_v), .wr_ready(bf_wr_ready), .wr_data(scr_d),
    .rd_valid(bf_rd_valid), .rd_ready(bf_rd_ready), .rd_data(bf_rd_data), .count(bf_count)
  );

  // ===================================================================== nibble source -> interleaver
  logic       il_in_ready;
  logic       il_in_valid;
  logic [3:0] il_in_data;
  if (CODED) begin : g_coded
    // bytes -> LDPC encoder (225 bytes per codeword, 2 codewords + 20 filler nibbles per OFDM symbol) -> nibbles
    logic       enc_in_ready, enc_out_valid;
    logic [3:0] enc_out_data;
    phy_ldpc_enc #(.FILL_WORDS(20)) u_enc (
      .clk, .rst, .cfg_mode(pkt_mode), .in_valid(bf_rd_valid), .in_ready(enc_in_ready), .in_data(bf_rd_data),
      .out_valid(enc_out_valid), .out_ready(il_in_ready), .out_data(enc_out_data)
    );
    assign bf_rd_ready = enc_in_ready;
    assign il_in_valid = enc_out_valid;
    assign il_in_data  = enc_out_data;
  end else begin : g_uncoded
    logic nib_phase;
    assign il_in_valid = bf_rd_valid;
    assign il_in_data  = nib_phase ? bf_rd_data[3:0] : bf_rd_data[7:4];
    assign bf_rd_ready = il_in_ready & nib_phase;
    always_ff @(posedge clk) begin
      if (rst) nib_phase <= 1'b0;
      else if (il_in_valid && il_in_ready) nib_phase <= ~nib_phase;
    end
  end

  logic       il_out_valid, il_out_ready, il_first, il_last;
  logic [3:0] il_out_data;
  phy_interleaver #(.WORD_W(BITS_PER_SYM), .ROT_UNIT(1)) u_il (
    .clk, .rst, .rot_en(CODED ? pkt_mode : 1'b1),
    .in_valid(il_in_valid), .in_ready(il_in_ready), .in_data(il_in_data),
    .out_valid(il_out_valid), .out_ready(il_out_ready), .out_data(il_out_data),
    .out_first(il_first), .out_last(il_last)
  );

  // ===================================================================== QAM mapper -> symbol FIFO -> OFDM mapper
  logic                   qm_valid;
  logic signed [IQ_W-1:0] qm_i, qm_q;
  logic                   qf_rd_valid, qf_rd_ready, qf_wr_ready;
  logic [2*IQ_W-1:0]      qf_rd_data;
  logic [3:0]             qf_count;

  logic                   hdr_pend, hdr_busy, hdr_busy_q, hdr_valid;
  logic signed [IQ_W-1:0] hdr_i, hdr_q;
  assign go_fire = go_valid && go_ready;
  assign il_out_ready = (qf_count <= 4'd5) && !(CODED && hdr_pend);
  logic                   qm16_valid, qmq_valid;
  logic signed [IQ_W-1:0] qm16_i, qm16_q, qmq_i, qmq_q;
  phy_qam_mapper #(.ORDER(QAM_ORDER)) u_qam (
    .clk, .rst, .in_valid(il_out_valid & il_out_ready), .in_last(1'b0), .in_bits(il_out_data),
    .out_valid(qm16_valid), .out_last(), .out_i(qm16_i), .out_q(qm16_q)
  );
  phy_qam_mapper #(.ORDER(4), .UNIT(QPSK_UNIT)) u_qpsk (
    .clk, .rst, .in_valid(il_out_valid & il_out_ready), .in_last(1'b0), .in_bits(il_out_data[1:0]),
    .out_valid(qmq_valid), .out_last(), .out_i(qmq_i), .out_q(qmq_q)
  );
  wire qpsk_sel = CODED && !pkt_mode;
  assign qm_valid = qpsk_sel ? qmq_valid : qm16_valid;
  assign qm_i     = qpsk_sel ? qmq_i : qm16_i;
  assign qm_q     = qpsk_sel ? qmq_q : qm16_q;

  // header symbol: 1100 QPSK bins that go into the symbol FIFO ahead of the data bins
  wire hdr_ready = (qf_count <= 4'd5);
  if (CODED) begin : g_hdr
    phy_hdr_gen u_hdr (
      .clk, .rst, .start(go_fire), .mode(wr_mode), .nsyms(pkt_nsyms), .out_valid(hdr_valid), .out_ready(hdr_ready),
      .out_i(hdr_i), .out_q(hdr_q), .busy(hdr_busy)
    );
  end else begin : g_nohdr
    assign hdr_valid = 1'b0; assign hdr_i = '0; assign hdr_q = '0; assign hdr_busy = 1'b0;
  end
  always_ff @(posedge clk) begin
    hdr_busy_q <= hdr_busy;
    if (rst) hdr_pend <= 1'b0;
    else if (go_fire && CODED) hdr_pend <= 1'b1;
    else if (hdr_pend && hdr_busy_q && !hdr_busy) hdr_pend <= 1'b0;
  end

  phy_fifo #(.W(2*IQ_W), .DEPTH(8)) u_qfifo (
    .clk, .rst, .wr_valid(hdr_busy ? (hdr_valid & hdr_ready) : qm_valid), .wr_ready(qf_wr_ready),
    .wr_data(hdr_busy ? {hdr_i, hdr_q} : {qm_i, qm_q}),
    .rd_valid(qf_rd_valid), .rd_ready(qf_rd_ready), .rd_data(qf_rd_data), .count(qf_count)
  );

  logic                   om_valid, om_pilot, om_first, om_last;
  logic signed [IQ_W-1:0] om_re, om_im;
  logic                   om_in_ready;
  assign qf_rd_ready = om_in_ready;
  phy_ofdm_mapper u_omap (
    .clk, .rst,
    .start_valid(map_start_valid), .start_ready(map_start_ready),
    .in_valid(qf_rd_valid), .in_ready(om_in_ready), .in_re(qf_rd_data[2*IQ_W-1:IQ_W]), .in_im(qf_rd_data[IQ_W-1:0]),
    .out_valid(om_valid), .out_re(om_re), .out_im(om_im), .out_pilot(om_pilot), .out_first(om_first), .out_last(om_last)
  );

  logic                   pi_valid, pi_first, pi_last;
  logic signed [IQ_W-1:0] pi_re, pi_im;
  phy_pilot_insert u_pilot (
    .clk, .rst, .in_valid(om_valid), .in_first(om_first), .in_last(om_last), .in_pilot(om_pilot), .in_re(om_re), .in_im(om_im),
    .out_valid(pi_valid), .out_first(pi_first), .out_last(pi_last), .out_re(pi_re), .out_im(pi_im)
  );

  // ===================================================================== preamble
  logic                   pr_valid, pr_first, pr_last;
  logic signed [IQ_W-1:0] pr_re, pr_im;
  phy_preamble_gen u_pre (
    .clk, .rst, .start_valid(pre_start_valid), .start_ready(pre_start_ready), .start_kind(pre_start_kind),
    .out_valid(pr_valid), .out_first(pr_first), .out_last(pr_last), .out_re(pr_re), .out_im(pr_im)
  );

  // ===================================================================== IFFT input mux (symbol sources are mutually exclusive)
  wire                   ff_valid = pr_valid | pi_valid | flush_valid;
  wire signed [IQ_W-1:0] ff_re    = pr_valid ? pr_re : pi_valid ? pi_re : '0;
  wire signed [IQ_W-1:0] ff_im    = pr_valid ? pr_im : pi_valid ? pi_im : '0;
  assign sym_end = (pr_valid & pr_last) | (pi_valid & pi_last);

  logic                   cp_valid, cp_first, cp_last, frame_ok;
  logic signed [IQ_W-1:0] cp_re, cp_im;
  if (!BF) begin : g_one
    logic                   if_valid, sc_valid;
    logic signed [IQ_W-1:0] if_re, if_im, sc_re, sc_im;
    phy_ifft_2048 #(.SHIFT_MASK(SHIFT_MASK)) u_ifft (
      .clk, .rst(rst | fft_rst), .in_valid(ff_valid), .in_re(ff_re), .in_im(ff_im),
      .out_valid(if_valid), .out_re(if_re), .out_im(if_im)
    );

    phy_tx_scaler u_scale (
      .clk, .rst, .gain, .in_valid(if_valid), .in_re(if_re), .in_im(if_im),
      .out_valid(sc_valid), .out_re(sc_re), .out_im(sc_im)
    );

    // ===================================================================== CP insert / reorder buffer -> IQ out
    phy_cp_insert u_cp (
      .clk, .rst, .in_valid(sc_valid), .in_re(sc_re), .in_im(sc_im),
      .frame_ok, .frame_written, .sym_done, .overflow,
      .out_valid(cp_valid), .out_ready(iq_pull), .out_re(cp_re), .out_im(cp_im), .out_first(cp_first), .out_last(cp_last)
    );
    assign iq1_re = '0;
    assign iq1_im = '0;
  end else begin : g_bf
    // two channels in lock-step: identical input stream and latency -> identical control outputs; channel 0 drives the frame
    // control, the overflow flags are or-ed.
    logic                   ovf [2], cv [2];
    logic signed [IQ_W-1:0] cre [2], cim [2];
    for (genvar c = 0; c < 2; c++) begin : g_ch
      logic                   w_valid, if_valid, sc_valid, fok, fw, sd, cf, cl;
      logic signed [IQ_W-1:0] w_re, w_im, if_re, if_im, sc_re, sc_im;
      phy_tx_weight u_w (
        .clk, .rst, .bin_rst(fft_rst), .load(go_fire), .mode_i(w_mode[2*c +: 2]), .amp_i(w_amp[16*c +: 16]),
        .phase_i(w_phase[16*c +: 16]), .tau_i(w_tau[17*c +: 17]),
        .in_valid(ff_valid), .in_re(ff_re), .in_im(ff_im), .out_valid(w_valid), .out_re(w_re), .out_im(w_im)
      );
      phy_ifft_2048 #(.SHIFT_MASK(SHIFT_MASK)) u_ifft (
        .clk, .rst(rst | fft_rst), .in_valid(w_valid), .in_re(w_re), .in_im(w_im),
        .out_valid(if_valid), .out_re(if_re), .out_im(if_im)
      );
      phy_tx_scaler u_scale (
        .clk, .rst, .gain, .in_valid(if_valid), .in_re(if_re), .in_im(if_im),
        .out_valid(sc_valid), .out_re(sc_re), .out_im(sc_im)
      );
      phy_cp_insert u_cp (
        .clk, .rst, .in_valid(sc_valid), .in_re(sc_re), .in_im(sc_im),
        .frame_ok(fok), .frame_written(fw), .sym_done(sd), .overflow(ovf[c]),
        .out_valid(cv[c]), .out_ready(iq_pull), .out_re(cre[c]), .out_im(cim[c]), .out_first(cf), .out_last(cl)
      );
      if (c == 0) begin : g_ctl
        assign frame_ok = fok; assign frame_written = fw; assign sym_done = sd; assign cp_first = cf; assign cp_last = cl;
      end
    end
    assign overflow = ovf[0] | ovf[1];
    assign cp_valid = cv[0];
    assign cp_re    = cre[0];
    assign cp_im    = cim[0];
    assign iq1_re   = cv[1] ? cre[1] : '0;
    assign iq1_im   = cv[1] ? cim[1] : '0;
  end

  assign iq_valid = cp_valid;
  assign iq_re    = cp_valid ? cp_re : '0;
  assign iq_im    = cp_valid ? cp_im : '0;
  assign busy     = ctrl_active | pkt_valid | cp_valid;

  always_ff @(posedge clk) begin
    if (rst) underflow <= 1'b0;
    else     underflow <= iq_pull & ~cp_valid & ctrl_active & tx_started_out;
  end

  // underflow is only meaningful after the first sample of the packet has left (continuous playback expected)
  always_ff @(posedge clk) begin
    if (rst) tx_started_out <= 1'b0;
    else if (cp_valid && iq_pull) tx_started_out <= 1'b1;
    else if (pkt_done || (!cp_valid && !ctrl_active)) tx_started_out <= 1'b0;   // also after the tail of the last frame played out
  end
endmodule
