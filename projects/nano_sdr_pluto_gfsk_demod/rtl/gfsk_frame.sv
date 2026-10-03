// ***************************************************************************
// GFSK RX: frame extraction. Pipelined: a bit is stored at en, the sync/preamble
// checks are registered, and the state machine acts one strobe later (en_q).
//   HUNT : sync 0x91D3 (<= SYNC_MAX_ERR bit errors) and the 48 bits before it an
//          alternating preamble (<= PRE_MAX_ERR errors, either polarity).
//          Preamble and sync are not whitened.
//   DATA : PN9 dewhitening (seed 0x1FF, first keystream bit = MSB of byte 0),
//          bytes MSB first. Byte 0 is L; the frame is L + 3 bytes.
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_frame #(
  parameter logic [15:0] SYNC_WORD    = 16'h91D3,
  parameter int          SYNC_MAX_ERR = 1,
  parameter int          PRE_MAX_ERR  = 4
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       en,              // bit strobe (19.2 kbit/s)
  input  logic       bit_in,
  output logic       frame_start,     // one pulse when sync is found
  output logic       byte_valid,      // one pulse per dewhitened byte
  output logic [7:0] byte_out,
  output logic       frame_done,      // one pulse after the last byte of a frame
  output logic [7:0] frame_len        // L of the last frame (valid at frame_done)
);
  typedef enum logic [0:0] {HUNT, DATA} state_t;
  state_t state = HUNT;

  logic [63:0] sr = '0;                // raw bit history, newest in bit 0
  logic [8:0]  lfsr = 9'h1FF;          // PN9 keystream generator
  logic [7:0]  sh = '0;
  logic [2:0]  bitcnt = '0;
  logic [8:0]  nbytes = '0;
  logic [8:0]  total = '0;

  // stage 1 (on en): history, flags from the history including this bit
  logic [63:0] sr_n;
  logic [15:0] sync_diff;
  logic [47:0] pre;
  logic        hit_sync_c, hit_pre_c;
  always_comb begin
    sr_n         = {sr[62:0], bit_in};
    sync_diff    = sr_n[15:0] ^ SYNC_WORD;
    pre          = sr_n[63:16];
    hit_sync_c   = ($countones(sync_diff) <= SYNC_MAX_ERR);
    hit_pre_c    = ($countones(pre ^ 48'hAAAAAAAAAAAA) <= PRE_MAX_ERR) ||
                   ($countones(pre ^ 48'h555555555555) <= PRE_MAX_ERR);
  end

  logic       en_q = 1'b0;
  logic       bq = 1'b0;               // this bit, delayed with the flags
  logic       hit_sync = 1'b0, hit_pre = 1'b0;
  always_ff @(posedge clk) begin
    en_q <= 1'b0;
    if (rst) begin
      sr <= '0;
    end else if (en) begin
      sr       <= sr_n;
      bq       <= bit_in;
      hit_sync <= hit_sync_c;
      hit_pre  <= hit_pre_c;
      en_q     <= 1'b1;
    end
  end

  // stage 2 (on en_q): state machine and byte assembly
  logic dbit, byte_done;
  logic [7:0] byte_now;
  always_comb begin
    dbit      = bq ^ lfsr[0];
    byte_now  = {sh[6:0], dbit};
    byte_done = (bitcnt == 3'd7);
  end

  always_ff @(posedge clk) begin
    frame_start <= 1'b0;
    byte_valid  <= 1'b0;
    frame_done  <= 1'b0;
    if (rst) begin
      state  <= HUNT;
      lfsr   <= 9'h1FF;
      bitcnt <= '0;
      nbytes <= '0;
      total  <= '0;
      sh     <= '0;
    end else if (en_q) begin
      unique case (state)
        HUNT: begin
          if (hit_sync && hit_pre) begin
            frame_start <= 1'b1;
            state       <= DATA;
            lfsr        <= 9'h1FF;
            bitcnt      <= '0;
            nbytes      <= '0;
            total       <= 9'd3;          // until the length byte is known
          end
        end
        DATA: begin
          lfsr <= {lfsr[0] ^ lfsr[5], lfsr[8:1]};
          sh   <= byte_now;
          if (byte_done) begin
            bitcnt     <= '0;
            byte_valid <= 1'b1;
            byte_out   <= byte_now;
            if (nbytes == 9'd0) begin
              frame_len <= byte_now;
              total     <= 9'(byte_now) + 9'd3;
            end
            nbytes <= nbytes + 1'b1;
            if (nbytes + 9'd1 == total && nbytes != 9'd0) begin
              frame_done <= 1'b1;
              state      <= HUNT;
            end
          end else begin
            bitcnt <= bitcnt + 1'b1;
          end
        end
        default: state <= HUNT;
      endcase
    end
  end
endmodule
