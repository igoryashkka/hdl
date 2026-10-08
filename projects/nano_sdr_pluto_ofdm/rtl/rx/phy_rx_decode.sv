// Module : phy_rx_decode   RX bit back-end (uncoded mode; the LDPC decoder slots in between the deinterleaver and the bit decision):
//   equalised/derotated data bins (valid-only, 1100 per OFDM symbol, in_first/in_last per symbol)
//   -> phy_qam_demapper (4 LLRs of 8 bit, packed MSB-first into a 32-bit word)
//   -> phy_interleaver (DEINT=1, word 32 bit, rotate unit 8)           (one symbol store-and-forward)
//   -> hard decision (LLR < 0 -> bit 1) -> nibble pairs -> byte (first nibble = high nibble)
//   -> phy_descrambler (seed restart at the first byte of a packet).
// Output: bytes (valid-only) with out_first (first byte of the packet) / out_last (last byte, after `nsyms` symbols).
//   `nsyms` is the number of data symbols of the packet (sampled at in_first of the first symbol); the byte counter and the
//   descrambler restart after out_last.  il_overflow latches if the deinterleaver could not accept a word (cannot happen
//   when the symbol spacing exceeds the read-out time).
// Latency: demapper 2 + one symbol (store-and-forward) + ~4 cycles.   Golden: python/rx_fixed_ref.py::decode_symbols (bit-exact)
module phy_rx_decode
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic [7:0]             nsyms,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic [7:0]             out_data,
  output logic                   il_overflow
);
  // ---------------------------------------------------------------- soft demapper
  logic                    dm_valid, dm_last;
  logic signed [LLR_W-1:0] dm_llr [BITS_PER_SYM];
  phy_qam_demapper #(.ORDER(QAM_ORDER)) u_dem (
    .clk, .rst, .in_valid, .in_last, .in_i(in_re), .in_q(in_im),
    .out_valid(dm_valid), .out_last(dm_last), .out_llr(dm_llr)
  );
  wire [31:0] dm_word = {dm_llr[0], dm_llr[1], dm_llr[2], dm_llr[3]};

  // ---------------------------------------------------------------- deinterleaver (one OFDM symbol per block)
  logic        di_in_ready, di_valid, di_first, di_last;
  logic [31:0] di_word;
  phy_interleaver #(.WORD_W(32), .ROT_UNIT(LLR_W), .DEINT(1'b1)) u_deint (
    .clk, .rst, .rot_en(1'b1), .in_valid(dm_valid), .in_ready(di_in_ready), .in_data(dm_word),
    .out_valid(di_valid), .out_ready(1'b1), .out_data(di_word), .out_first(di_first), .out_last(di_last)
  );
  always_ff @(posedge clk) begin
    if (rst) il_overflow <= 1'b0;
    else if (dm_valid && !di_in_ready) il_overflow <= 1'b1;
  end

  // ---------------------------------------------------------------- hard decision, nibble pairing, symbol/byte counting
  wire [3:0] nib = {di_word[31], di_word[23], di_word[15], di_word[7]};
  logic       phase;
  logic [3:0] nib_hi;
  logic       by_valid, by_last, by_first;
  logic [7:0] by_data;
  logic [7:0] sym_cnt;           // symbols completed in this packet
  logic       pkt_start;         // next byte is the first of the packet
  logic [7:0] nsyms_l;

  always_ff @(posedge clk) begin
    by_valid <= 1'b0;
    if (rst) begin
      phase <= 1'b0; sym_cnt <= '0; pkt_start <= 1'b1; nsyms_l <= '0; by_last <= 1'b0; by_first <= 1'b0; by_data <= '0; nib_hi <= '0;
    end else if (di_valid) begin
      if (di_first && sym_cnt == 8'd0) nsyms_l <= nsyms;
      if (!phase) begin
        nib_hi <= nib; phase <= 1'b1;
      end else begin
        by_valid <= 1'b1; by_data <= {nib_hi, nib}; phase <= 1'b0;
        by_first <= pkt_start; pkt_start <= 1'b0;
        by_last  <= di_last && (sym_cnt + 8'd1 == nsyms_l);
      end
      if (di_last) begin
        if (sym_cnt + 8'd1 == nsyms_l) begin sym_cnt <= '0; pkt_start <= 1'b1; end
        else sym_cnt <= sym_cnt + 8'd1;
      end
    end
  end

  // ---------------------------------------------------------------- descrambler (first byte restarts the sequence)
  phy_descrambler u_desc (
    .clk, .rst, .in_valid(by_valid), .in_first(by_first), .in_last(by_last), .in_data(by_data),
    .out_valid, .out_first, .out_last, .out_data
  );
endmodule
