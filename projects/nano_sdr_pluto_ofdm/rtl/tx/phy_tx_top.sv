// Module : phy_tx_top   OFDM PHY transmitter (uncoded mode; LDPC slot reserved between scrambler and interleaver).
//   bytes -> packet buffer -> scrambler -> nibbles -> interleaver -> 16-QAM mapper -> OFDM mapper -> pilot insert
//   -> (mux with preamble) -> IFFT -> digital scaler -> bit-reverse + cyclic prefix buffer -> IQ (pulled at sample rate)
// Packet: s_valid/s_ready/s_data/s_last; payload is padded with zeros to a multiple of BYTES_PER_OFDM (550) bytes
//   (one OFDM symbol). Max TX_MAX_SYMS symbols (4400 bytes); longer packets are truncated (pkt_trunc flag).
// Output: iq_pull (sample strobe from the DAC interface) -> iq_re/iq_im valid the same cycle (0 when nothing to send).
//   `underflow` pulses when a sample was pulled during an active packet but none was ready (should never happen).
// Timing contract: after a packet is complete, the first sample is available after ~2 symbol compute times; samples of one
//   frame are then continuous at the pull rate (credit logic in phy_tx_frame_ctrl guarantees banks are filled in time as
//   long as the processing clock is >= 2x the sample rate).
// Golden: python/tx_ref.py::tx_frame (whole chain, bit-exact incl. fixed-point IFFT, scaling and CP).
module phy_tx_top
  import phy_pkg::*;
#(
  parameter int MAX_SYMS   = TX_MAX_SYMS,
  parameter int SHIFT_MASK = 32'h0FF
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic [15:0]            gain,           // Q2.14, 16384 = 1.0
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
  output logic                   busy
);
  localparam int BUF_BYTES = MAX_SYMS * BYTES_PER_OFDM;
  localparam int BAW       = $clog2(BUF_BYTES);

  // ===================================================================== packet buffer (receive side)
  logic [7:0]     bbuf [BUF_BYTES];
  logic [BAW-1:0] wr_ptr;
  logic [BAW:0]   pkt_len;                    // bytes stored
  logic [9:0]     sym_byte_cnt;
  logic [7:0]     nsyms_acc, pkt_nsyms;
  logic           pkt_valid;                  // a complete packet is waiting for / being sent
  logic           rd_busy;                    // reader is streaming the packet out of the buffer
  logic           go_ready;
  logic           rd_done;
  logic           tx_started_out;

  assign s_ready = ~pkt_valid;
  wire   wr_en   = s_valid & s_ready;
  wire   wr_end  = s_last | (wr_ptr == BAW'(BUF_BYTES - 1));

  always_ff @(posedge clk) begin
    if (wr_en) bbuf[wr_ptr] <= s_data;
    if (rst) begin
      wr_ptr <= '0; pkt_len <= '0; sym_byte_cnt <= '0; nsyms_acc <= '0; pkt_nsyms <= '0;
      pkt_valid <= 1'b0; pkt_trunc <= 1'b0;
    end else begin
      if (wr_en) begin
        if (sym_byte_cnt == 10'(BYTES_PER_OFDM - 1)) begin sym_byte_cnt <= '0; nsyms_acc <= nsyms_acc + 1'b1; end
        else sym_byte_cnt <= sym_byte_cnt + 1'b1;
        if (wr_end) begin
          pkt_len   <= (BAW+1)'(wr_ptr) + 1'b1;
          pkt_nsyms <= nsyms_acc + 1'b1;
          pkt_valid <= 1'b1;
          pkt_trunc <= ~s_last;
        end else wr_ptr <= wr_ptr + 1'b1;
      end
      if (pkt_valid && !rd_busy && rd_done) begin       // buffer fully read out -> accept the next packet
        pkt_valid <= 1'b0; wr_ptr <= '0; sym_byte_cnt <= '0; nsyms_acc <= '0;
      end
    end
  end

  // ===================================================================== frame controller
  logic pre_start_valid, pre_start_ready, pre_start_kind, map_start_valid, map_start_ready;
  logic sym_end, flush_valid, frame_written, sym_done, fft_rst, ctrl_active;
  logic go_valid;

  // the reader starts together with the controller (go handshake); `started_pkt` marks the packet as taken
  logic pkt_taken;
  assign go_valid = pkt_valid && !pkt_taken;

  phy_tx_frame_ctrl u_ctrl (
    .clk, .rst,
    .go_valid, .go_ready, .go_nsyms(pkt_nsyms),
    .pre_start_valid, .pre_start_ready, .pre_start_kind,
    .map_start_valid, .map_start_ready,
    .sym_end, .flush_valid, .frame_written, .sym_done,
    .fft_rst, .pkt_done, .active(ctrl_active)
  );

  // ===================================================================== reader: buffer -> scrambler -> byte FIFO
  logic [BAW:0]  total_bytes;                 // padded length
  logic [BAW:0]  rd_idx;
  logic          a_v, a_first, a_last, a_pad;
  logic [7:0]    ram_q;
  logic          scr_v, scr_first, scr_last; logic [7:0] scr_d;
  logic          bf_wr_ready, bf_rd_valid, bf_rd_ready; logic [7:0] bf_rd_data; logic [3:0] bf_count;

  wire rd_issue = rd_busy && (rd_idx != total_bytes) && ((bf_count + 4'(a_v) + 4'(scr_v)) < 4'd6);

  always_ff @(posedge clk) begin
    ram_q <= bbuf[rd_idx[BAW-1:0]];
    rd_done <= 1'b0;
    if (rst) begin
      rd_busy <= 1'b0; rd_idx <= '0; total_bytes <= '0; a_v <= 1'b0; pkt_taken <= 1'b0;
    end else begin
      if (go_valid && go_ready) begin
        pkt_taken   <= 1'b1;
        rd_busy     <= 1'b1;
        rd_idx      <= '0;
        total_bytes <= (BAW+1)'(pkt_nsyms) * (BAW+1)'(BYTES_PER_OFDM);
      end
      a_v <= rd_issue;
      if (rd_issue) begin
        a_first <= (rd_idx == '0);
        a_last  <= (rd_idx == total_bytes - 1'b1);
        a_pad   <= (rd_idx >= pkt_len);
        rd_idx  <= rd_idx + 1'b1;
      end
      if (rd_busy && rd_idx == total_bytes && !a_v && !scr_v) begin
        rd_busy <= 1'b0; rd_done <= 1'b1;
      end
      if (rd_done) pkt_taken <= 1'b0;
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

  // ===================================================================== nibble serializer -> interleaver
  logic       nib_phase, il_in_ready;
  wire        il_in_valid = bf_rd_valid;
  wire [3:0]  il_in_data  = nib_phase ? bf_rd_data[3:0] : bf_rd_data[7:4];
  assign bf_rd_ready = il_in_ready & nib_phase;
  always_ff @(posedge clk) begin
    if (rst) nib_phase <= 1'b0;
    else if (il_in_valid && il_in_ready) nib_phase <= ~nib_phase;
  end

  logic       il_out_valid, il_out_ready, il_first, il_last;
  logic [3:0] il_out_data;
  phy_interleaver #(.WORD_W(BITS_PER_SYM), .ROT_UNIT(1)) u_il (
    .clk, .rst,
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

  assign il_out_ready = (qf_count <= 4'd5);
  phy_qam_mapper #(.ORDER(QAM_ORDER)) u_qam (
    .clk, .rst, .in_valid(il_out_valid & il_out_ready), .in_last(1'b0), .in_bits(il_out_data),
    .out_valid(qm_valid), .out_last(), .out_i(qm_i), .out_q(qm_q)
  );

  phy_fifo #(.W(2*IQ_W), .DEPTH(8)) u_qfifo (
    .clk, .rst, .wr_valid(qm_valid), .wr_ready(qf_wr_ready), .wr_data({qm_i, qm_q}),
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
  logic                   cp_valid, cp_first, cp_last, frame_ok;
  logic signed [IQ_W-1:0] cp_re, cp_im;
  phy_cp_insert u_cp (
    .clk, .rst, .in_valid(sc_valid), .in_re(sc_re), .in_im(sc_im),
    .frame_ok, .frame_written, .sym_done, .overflow,
    .out_valid(cp_valid), .out_ready(iq_pull), .out_re(cp_re), .out_im(cp_im), .out_first(cp_first), .out_last(cp_last)
  );

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
    else if (pkt_done) tx_started_out <= 1'b0;
  end
endmodule
