// Module : phy_rx_decode_ldpc   RX bit back-end of the coded PHY (replaces phy_rx_decode):
//   derotated data bins (valid-only, 1100 per OFDM symbol) -> phy_llr_demap (6 bit LLRs, per-bin parameters from phy_mmse_post)
//   -> symbol deinterleaver (24 bit words = 4 LLRs, rotate unit 6) -> LDPC decoder (words 0..1079 = two codewords of 540 words,
//   the last 20 filler words of every symbol are dropped) -> 225 bytes per codeword -> descrambler.
//   Output: bytes (valid-only) with out_first (first byte of the packet) and out_last (last byte, after 2 * nsyms codewords).
//   Statistics per packet (valid with the last byte): number of codewords that did not converge, maximum and total iterations.
// Golden: python/phy2_ref.py (decode path) with python/ldpc_fixed_ref.py (decoder, bit-exact)
module phy_rx_decode_ldpc
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic [7:0]             nsyms,
  input  logic [4:0]             cfg_max_iter,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic [10:0]            prm_ra,
  input  logic [28:0]            prm_rd,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic [7:0]             out_data,
  output logic                   il_overflow,
  output logic                   stat_valid,         // with out_last
  output logic [7:0]             stat_fail,          // codewords not converged in this packet
  output logic [4:0]             stat_iter_max,
  output logic [11:0]            stat_iter_sum,
  output logic                   cw_pulse,           // one pulse per decoded codeword
  output logic                   cw_fail_pulse
);
  // ---------------------------------------------------------------- soft demapper
  logic                 dm_valid, dm_first, dm_last;
  logic signed [5:0]    dm_llr [4];
  phy_llr_demap u_dm (
    .clk, .rst, .in_valid, .in_first, .in_last, .in_re, .in_im, .rd_addr(prm_ra), .rd_data(prm_rd),
    .out_valid(dm_valid), .out_first(dm_first), .out_last(dm_last), .out_llr(dm_llr)
  );
  wire [23:0] dm_word = {dm_llr[0], dm_llr[1], dm_llr[2], dm_llr[3]};

  // ---------------------------------------------------------------- deinterleaver
  logic        di_in_ready, di_valid, di_first, di_last, di_ready;
  logic [23:0] di_word;
  phy_interleaver #(.WORD_W(24), .ROT_UNIT(6), .DEINT(1'b1)) u_deint (
    .clk, .rst, .in_valid(dm_valid), .in_ready(di_in_ready), .in_data(dm_word),
    .out_valid(di_valid), .out_ready(di_ready), .out_data(di_word), .out_first(di_first), .out_last(di_last)
  );
  always_ff @(posedge clk) begin
    if (rst) il_overflow <= 1'b0;
    else if (dm_valid && !di_in_ready) il_overflow <= 1'b1;
  end

  // ---------------------------------------------------------------- word counter inside the symbol: 0..1079 -> decoder, 1080..1099 dropped
  logic [10:0] wcnt;
  logic        dec_in_ready;
  wire         to_dec = (wcnt < 11'd1080);
  assign di_ready = to_dec ? dec_in_ready : 1'b1;
  wire         di_fire = di_valid && di_ready;
  always_ff @(posedge clk) begin
    if (rst) wcnt <= '0;
    else if (di_fire) wcnt <= di_last ? 11'd0 : wcnt + 1'b1;
  end

  // packet framing: nsyms sampled at the first word of the first symbol
  logic [7:0] sym_cnt, nsyms_l;
  always_ff @(posedge clk) begin
    if (rst) begin sym_cnt <= '0; nsyms_l <= '0; end
    else if (di_fire) begin
      if (di_first && sym_cnt == 8'd0) nsyms_l <= nsyms;
      if (di_last) sym_cnt <= (sym_cnt + 8'd1 == nsyms_l) ? 8'd0 : sym_cnt + 8'd1;
    end
  end

  // ---------------------------------------------------------------- LDPC decoder
  logic signed [5:0] ld_llr [4];
  always_comb begin
    ld_llr[0] = di_word[23:18]; ld_llr[1] = di_word[17:12]; ld_llr[2] = di_word[11:6]; ld_llr[3] = di_word[5:0];
  end
  logic        ld_valid, ld_first, ld_last, ld_st_valid, ld_st_ok, ld_busy;
  logic [7:0]  ld_data;
  logic [4:0]  ld_st_iter;
  phy_ldpc_dec u_ldpc (
    .clk, .rst, .cfg_max_iter,
    .in_valid(di_valid && to_dec), .in_ready(dec_in_ready), .in_llr(ld_llr),
    .out_valid(ld_valid), .out_first(ld_first), .out_last(ld_last), .out_data(ld_data),
    .st_valid(ld_st_valid), .st_ok(ld_st_ok), .st_iter(ld_st_iter), .busy(ld_busy)
  );

  // ---------------------------------------------------------------- codeword / packet bookkeeping
  logic [8:0]  cw_cnt;                   // codewords output in this packet
  logic        pkt_first;
  logic        d_valid, d_first, d_last; logic [7:0] d_data;
  logic [7:0]  fail_acc; logic [4:0] imax_acc; logic [11:0] isum_acc;
  wire  [8:0]  cw_total = {nsyms_l, 1'b0};
  logic        last_cw;                  // registered: cw_cnt changes only once per codeword, a one-cycle lag is invisible
  always_ff @(posedge clk) last_cw <= (cw_cnt + 9'd1 == cw_total);
  always_ff @(posedge clk) begin
    d_valid <= ld_valid; d_data <= ld_data; d_first <= 1'b0; d_last <= 1'b0; stat_valid <= 1'b0;
    cw_pulse <= 1'b0; cw_fail_pulse <= 1'b0;
    if (rst) begin cw_cnt <= '0; pkt_first <= 1'b1; fail_acc <= '0; imax_acc <= '0; isum_acc <= '0; end
    else begin
      if (ld_valid) begin
        d_first <= pkt_first && ld_first; if (ld_first) pkt_first <= 1'b0;
        d_last  <= ld_last && last_cw;
      end
      if (ld_st_valid) begin
        cw_pulse <= 1'b1; cw_fail_pulse <= !ld_st_ok;
        fail_acc <= fail_acc + (ld_st_ok ? 8'd0 : 8'd1);
        if (ld_st_iter > imax_acc) imax_acc <= ld_st_iter;
        isum_acc <= isum_acc + 12'(ld_st_iter);
        if (last_cw) begin
          stat_valid <= 1'b1; stat_fail <= fail_acc + (ld_st_ok ? 8'd0 : 8'd1);
          stat_iter_max <= (ld_st_iter > imax_acc) ? ld_st_iter : imax_acc; stat_iter_sum <= isum_acc + 12'(ld_st_iter);
          cw_cnt <= '0; pkt_first <= 1'b1; fail_acc <= '0; imax_acc <= '0; isum_acc <= '0;
        end else cw_cnt <= cw_cnt + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------- descrambler
  phy_descrambler u_desc (
    .clk, .rst, .in_valid(d_valid), .in_first(d_first), .in_last(d_last), .in_data(d_data),
    .out_valid, .out_first, .out_last, .out_data
  );
endmodule
