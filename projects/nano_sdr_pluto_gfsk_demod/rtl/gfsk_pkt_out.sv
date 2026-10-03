// ***************************************************************************
// GFSK RX: packet record builder and AXI-stream output (to axi_dmac, stream source).
//
// One record per frame, always 32 bytes (4 x 64-bit beats, little-endian bytes):
//   [0]     0xA5 magic
//   [1]     flags: bit0 CRC8 ok, bit1 radio CRC16 ok, bit2 length == 13,
//                  bit3 frame longer than 16 bytes, bit4 frame shorter than 16 bytes
//   [2]     length byte L of the frame
//   [3]     channel index (0)
//   [4..7]  packet counter, big-endian (all frames of this channel, starting at 1)
//   [8..11] input sample counter at frame start (4.5 MS/s), big-endian
//   [12..27] first 16 dewhitened frame bytes (length .. radio CRC16)
//   [28..31] zero
//
// CRC rules (firmware / hopdet), computed incrementally as the bytes arrive:
//   CRC8  = XOR of frame bytes 2..12, start 0x77, compared with byte 13
//   CRC16 = poly 0x1021, start 0x1D0F, over bytes 0..13, output XOR 0xFFFF, big-endian in bytes 14..15
//
// A record finished while the previous one is still being sent is dropped and counted.
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_pkt_out (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,          // input sample strobe (sample counter)
  input  logic        frame_start,
  input  logic        byte_valid,
  input  logic [7:0]  byte_out,
  input  logic        frame_done,
  input  logic [7:0]  frame_len,
  output logic        m_axis_valid,
  input  logic        m_axis_ready,
  output logic [63:0] m_axis_data,
  output logic        m_axis_last,
  output logic [15:0] drops               // records lost because the output was busy
);
  // ---- counters ------------------------------------------------------------
  logic [31:0] sample_cnt = '0;
  logic [31:0] pkt_cnt    = '0;
  logic [31:0] ts_start   = '0;

  // ---- frame buffer and incremental CRCs -----------------------------------
  logic [7:0]  fb [0:15];
  logic [7:0]  nb    = '0;               // bytes received in this frame (saturates at 255)
  logic        trunc = 1'b0;
  logic [15:0] crc16 = 16'h1D0F;
  logic [7:0]  crc8  = 8'h77;

  // ---- record ---------------------------------------------------------------
  logic [255:0] rec = '0;
  logic         busy = 1'b0;
  logic [1:0]   beat = '0;
  logic         frame_done_d = 1'b0;   // frame_done is one clock ahead of its last byte
  logic [31:0]  pkt_cnt_n;
  assign pkt_cnt_n = pkt_cnt + 1'b1;

  function automatic logic [15:0] crc16_step (input logic [15:0] c, input logic [7:0] b);
    logic [15:0] r;
    r = c ^ {b, 8'h00};
    for (int k = 0; k < 8; k++)
      r = r[15] ? ((r << 1) ^ 16'h1021) : (r << 1);
    return r;
  endfunction

  // ---- check at frame end ---------------------------------------------------
  logic have16, len13, ok8, ok16;
  always_comb begin
    have16 = (nb >= 8'd16);
    len13  = (frame_len == 8'd13);
    ok8    = have16 && len13 && (crc8 == fb[13]);
    ok16   = have16 && len13 && ((crc16 ^ 16'hFFFF) == {fb[14], fb[15]});
  end

  // ---- sequential ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (in_valid) sample_cnt <= sample_cnt + 1'b1;
    frame_done_d <= frame_done;

    if (rst) begin
      nb           <= '0;
      trunc        <= 1'b0;
      busy         <= 1'b0;
      beat         <= '0;
      pkt_cnt      <= '0;
      drops        <= '0;
      m_axis_valid <= 1'b0;
    end else begin
      if (frame_start) begin
        nb       <= '0;
        trunc    <= 1'b0;
        ts_start <= sample_cnt;
        crc16    <= 16'h1D0F;
        crc8     <= 8'h77;
      end

      if (byte_valid) begin
        if (nb < 8'd16) fb[nb[3:0]] <= byte_out;
        else            trunc <= 1'b1;
        if (nb < 8'd14)                       crc16 <= crc16_step(crc16, byte_out);
        if (nb >= 8'd2 && nb <= 8'd12)        crc8  <= crc8 ^ byte_out;
        if (nb != 8'hFF) nb <= nb + 1'b1;
      end

      if (frame_done_d) begin
        pkt_cnt <= pkt_cnt + 1'b1;
        if (busy || m_axis_valid) begin
          drops <= drops + 1'b1;
        end else begin
          rec[7:0]     <= 8'hA5;
          rec[15:8]    <= {3'b000, (nb < 8'd16), trunc, len13, ok16, ok8};
          rec[23:16]   <= frame_len;
          rec[31:24]   <= 8'h00;
          rec[39:32]   <= pkt_cnt_n[31:24];
          rec[47:40]   <= pkt_cnt_n[23:16];
          rec[55:48]   <= pkt_cnt_n[15:8];
          rec[63:56]   <= pkt_cnt_n[7:0];
          rec[71:64]   <= ts_start[31:24];
          rec[79:72]   <= ts_start[23:16];
          rec[87:80]   <= ts_start[15:8];
          rec[95:88]   <= ts_start[7:0];
          for (int i = 0; i < 16; i++) rec[96 + 8*i +: 8] <= fb[i];
          rec[255:224] <= '0;
          busy         <= 1'b1;
          beat         <= '0;
          m_axis_valid <= 1'b1;
        end
      end

      // stream out: 4 beats of 64 bits
      if (m_axis_valid && m_axis_ready) begin
        beat <= beat + 1'b1;
        if (beat == 2'd3) begin
          m_axis_valid <= 1'b0;
          busy         <= 1'b0;
        end
      end
    end
  end

  always_comb begin
    m_axis_data = rec[64*beat +: 64];
    m_axis_last = (beat == 2'd3);
  end
endmodule
