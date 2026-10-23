// Module : phy_syncbus   board-to-board bus over the JP5 header (TestTask006): SCLK / MOSI from the leader, UP from the follower.
//   SPI mode 0 (data changes while SCLK is low, sampled on the rising edge), MSB first, no chip select: frames start with A5 5A.
//   Frame: [A5][5A][type][seq][len][payload, len bytes][crc16 hi][crc16 lo], CRC16-CCITT (0x1021, init FFFF) over type..payload.
//   Leader (role 1): tx_start sends tx_len raw bytes of tx_buf (software builds the frame incl. CRC), then keeps SCLK low for GAP
//     half periods and clocks RESP_LEN bytes of the response in from UP (sampled on its own rising edge), checks sync + CRC:
//     resp_ok / resp_bad pulse, resp_last = last good response (type..payload, i.e. without sync / CRC).
//   Follower (role 2): SCLK / MOSI through 2-FF synchronisers; bit hunt for A5 5A after an idle period, then type/seq/len/payload/crc;
//     rx_ok / rx_bad pulse; rx_last = last good frame (type, seq, len, payload). Frames longer than RXMAX bytes are rejected.
//     After the CRC (good or bad) it answers with RESP_LEN bytes: [A5][5A][81][seq][16][status u16][crc_err u16][epoch u32][ts u64]
//     [crc], fields little-endian, sampled at the end of the frame. UP is driven only while answering (Hi-Z otherwise).
//   Idle: no SCLK edge for IDLE_HP half periods -> follower returns to the hunt (resynchronises after any error).
//   Leader frame spacing: a start request (tx_start) is latched and served once SCLK has been idle for (IDLE_HP + 4) half periods,
//   so the follower is always back in the hunt state before the next frame.
//   Pins: *_o / *_t (t = 1 -> Hi-Z) per role; role 0: all Hi-Z.   div: SCLK half period in clocks (>= 10; 12 -> 5.12 MHz at 122.88 MHz).
// Golden: python/bf_ref.py (frame / resp_frame / crc16). Verified by tb_phy_syncbus (leader + follower on unrelated clocks).
module phy_syncbus #(
  parameter int TXMAX    = 48,
  parameter int RXMAX    = 48,       // type..payload bytes kept by the follower
  parameter int RESP_LEN = 23,
  parameter int GAP      = 8,        // half periods between the frame and the response
  parameter int IDLE_HP  = 12
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic [1:0]           role,
  input  logic [7:0]           div,
  // leader
  input  logic                 tx_start,
  input  logic [5:0]           tx_len,
  input  logic [8*TXMAX-1:0]   tx_buf,          // byte i at [8*i +: 8]
  output logic                 tx_busy,
  output logic                 resp_ok,
  output logic                 resp_bad,
  output logic [8*(RESP_LEN-4)-1:0] resp_last,  // type, seq, len, 16 payload bytes
  // follower
  output logic                 rx_ok,
  output logic                 rx_bad,
  output logic [8*RXMAX-1:0]   rx_last,         // type, seq, len, payload
  output logic [8*RXMAX-1:0]   rx_work,         // frame being received (valid in the rx_ok cycle)
  output logic [15:0]          rx_crc_err,
  input  logic [15:0]          resp_status,
  input  logic [31:0]          resp_epoch,
  input  logic [63:0]          resp_ts,
  // pins
  input  logic                 sclk_i, mosi_i, up_i,
  output logic                 sclk_o, mosi_o, up_o,
  output logic                 sclk_t, mosi_t, up_t
);
  localparam int RL = RESP_LEN - 4;          // response bytes kept (type..payload)

  function automatic logic [15:0] crc_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] r;
    r = c ^ {b, 8'h00};
    for (int i = 0; i < 8; i++) r = r[15] ? ((r << 1) ^ 16'h1021) : (r << 1);
    return r;
  endfunction

  wire leader = (role == 2'd1), follower = (role == 2'd2);
  assign sclk_t = ~leader;
  assign mosi_t = ~leader;

  // ================================================================== leader
  typedef enum logic [1:0] {L_IDLE, L_TX, L_GAP, L_RX} lst_t;
  lst_t           lst;
  logic [7:0]     hp;                         // half-period counter
  logic [8:0]     lbit;                       // bit index in the current phase
  logic [5:0]     lbytes;
  logic [7:0]     lsh;
  logic [15:0]    lcrc;
  logic [8*RESP_LEN-1:0] lresp;
  logic           tx_req;
  logic [15:0]    lidle;
  (* ASYNC_REG = "TRUE" *) logic up_s1, up_s2;
  always_ff @(posedge clk) begin up_s1 <= up_i; up_s2 <= up_s1; end

  wire hp_end = (hp >= div - 1);
  always_ff @(posedge clk) begin
    resp_ok <= 1'b0; resp_bad <= 1'b0;
    if (rst || !leader) begin
      lst <= L_IDLE; sclk_o <= 1'b0; mosi_o <= 1'b0; hp <= '0; lbit <= '0; lbytes <= '0; tx_busy <= 1'b0; tx_req <= 1'b0; lidle <= '0;
    end else begin
      if (tx_start && tx_len != 0) begin tx_req <= 1'b1; tx_busy <= 1'b1; end
      case (lst)
        L_IDLE: begin
          sclk_o <= 1'b0; hp <= '0;
          if (lidle != 16'hFFFF) lidle <= lidle + 1'b1;
          if (tx_req && lidle >= 16'(IDLE_HP + 4) * div) begin
            lst <= L_TX; tx_req <= 1'b0; lbit <= '0; lbytes <= tx_len;
            mosi_o <= tx_buf[7];
          end
        end
        L_TX: begin
          hp <= hp_end ? '0 : hp + 1'b1;
          if (hp_end) begin
            sclk_o <= ~sclk_o;
            if (sclk_o) begin                                     // falling edge: next bit
              if (lbit == 9'(8 * lbytes - 1)) begin lst <= L_GAP; lbit <= '0; mosi_o <= 1'b0; end
              else begin
                lbit <= lbit + 1'b1;
                mosi_o <= tx_buf[8 * ((lbit + 1) >> 3) + (7 - ((lbit + 1) & 7))];
              end
            end
          end
        end
        L_GAP: begin
          hp <= hp_end ? '0 : hp + 1'b1;
          if (hp_end) begin
            lbit <= lbit + 1'b1;
            if (lbit == 9'(GAP - 1)) begin lst <= L_RX; lbit <= '0; lcrc <= 16'hFFFF; end
          end
        end
        default: begin                                            // L_RX
          hp <= hp_end ? '0 : hp + 1'b1;
          if (hp_end) begin
            sclk_o <= ~sclk_o;
            if (!sclk_o) begin                                    // rising edge: sample UP (synchronised: 2 clocks of delay << half period)
              lsh <= {lsh[6:0], up_s2};
              lresp <= {lresp[8*RESP_LEN-2:0], up_s2};
            end else begin                                        // falling edge after a bit
              lbit <= lbit + 1'b1;
              if (lbit[2:0] == 3'd7 && lbit >= 9'd16 && lbit < 9'(8 * (RESP_LEN - 2))) lcrc <= crc_byte(lcrc, lsh);
              if (lbit == 9'(8 * RESP_LEN - 1)) begin
                lst <= L_IDLE; tx_busy <= tx_req | (tx_start && tx_len != 0); lidle <= '0;
                // lresp holds the response MSB-first: byte 0 at the top
                if (lresp[8*RESP_LEN-1 -: 16] == 16'hA55A && lcrc == {lresp[15:8], lresp[7:0]}) begin
                  resp_ok <= 1'b1;
                  for (int i = 0; i < RL; i++) resp_last[8*i +: 8] <= lresp[8*(RESP_LEN-3-i) +: 8];
                end else resp_bad <= 1'b1;
              end
            end
          end
        end
      endcase
    end
  end

  // ================================================================== follower
  (* ASYNC_REG = "TRUE" *) logic sc_s1, sc_s2, mo_s1, mo_s2;
  logic sc_s3;
  always_ff @(posedge clk) begin sc_s1 <= sclk_i; sc_s2 <= sc_s1; sc_s3 <= sc_s2; mo_s1 <= mosi_i; mo_s2 <= mo_s1; end
  wire rise = sc_s2 & ~sc_s3, fall = ~sc_s2 & sc_s3;

  typedef enum logic [1:0] {F_HUNT, F_RX, F_RESP, F_WAIT} fst_t;
  fst_t        fst;
  logic [15:0] fsh;
  logic [2:0]  fbit;
  logic [7:0]  fpos;                          // bytes received after the sync (type = 0)
  logic [7:0]  flen;
  logic [15:0] fcrc;
  logic [15:0] idle;
  logic [8*RESP_LEN-1:0] rsh;
  logic [7:0]  rbits;
  logic        r_armed;                       // first response rising edge seen (earlier falling edges belong to the frame)
  logic [7:0]  seq_q;
  logic [4:0]  rbuild;                        // response CRC sequencer
  logic [15:0] rcrc;
  wire  [15:0] idle_lim = 16'(IDLE_HP) * div;
  wire  [7:0]  byte_in = {fsh[6:0], mo_s2};

  // response bytes (type .. payload), little-endian fields
  logic [8*RL-1:0] rbody;
  always_comb begin
    rbody = '0;
    rbody[0 +: 8]   = 8'h81;
    rbody[8 +: 8]   = seq_q;
    rbody[16 +: 8]  = 8'd16;
    rbody[24 +: 16] = resp_status;
    rbody[40 +: 16] = rx_crc_err;
    rbody[56 +: 32] = resp_epoch;
    rbody[88 +: 64] = resp_ts;
  end
  logic [8*RL-1:0] rbody_q;
  function automatic logic [8*RL-1:0] wire_order(input logic [8*RL-1:0] v);     // byte 0 (LSB) first = most significant
    for (int i = 0; i < RL; i++) wire_order[8*(RL-1-i) +: 8] = v[8*i +: 8];
  endfunction

  always_ff @(posedge clk) begin
    rx_ok <= 1'b0; rx_bad <= 1'b0;
    if (rst || !follower) begin
      fst <= F_HUNT; fsh <= '0; fbit <= '0; fpos <= '0; idle <= '0; up_t <= 1'b1; up_o <= 1'b1; rx_crc_err <= '0; rbuild <= '0;
    end else begin
      idle <= (rise || fall) ? '0 : ((idle == 16'hFFFF) ? idle : idle + 1'b1);
      if (idle >= idle_lim && fst != F_HUNT) begin fst <= F_HUNT; up_t <= 1'b1; fsh <= '0; end
      // response CRC: one byte per clock after the frame end
      if (rbuild == 5'd1) begin                                   // fields one clock after the frame end (crc_err counts this frame)
        rbody_q <= rbody; rcrc <= 16'hFFFF; rbuild <= 5'd2;
      end else if (rbuild != 0) begin
        if (rbuild <= 5'(RL + 1)) begin
          rcrc <= crc_byte(rcrc, rbody_q[8*(rbuild-2) +: 8]);
          rbuild <= rbuild + 1'b1;
        end else begin
          rsh <= {8'hA5, 8'h5A, wire_order(rbody_q), rcrc};    // MSB first on the wire
          rbuild <= '0;
          fst <= F_RESP; rbits <= '0; up_t <= 1'b0; up_o <= 1'b1; r_armed <= 1'b0;
        end
      end
      case (fst)
        F_HUNT: if (rise) begin
          fsh <= {fsh[14:0], mo_s2};
          if ({fsh[14:0], mo_s2} == 16'hA55A) begin fst <= F_RX; fbit <= '0; fpos <= '0; fcrc <= 16'hFFFF; flen <= '0; end
        end
        F_RX: if (rise) begin
          fsh  <= {fsh[14:0], mo_s2};
          fbit <= fbit + 1'b1;
          if (fbit == 3'd7) begin
            fpos <= fpos + 1'b1;
            if (fpos < 8'(RXMAX)) rx_work[8*fpos +: 8] <= byte_in;
            if (fpos == 8'd1) seq_q <= byte_in;
            if (fpos == 8'd2) flen <= byte_in;
            if (fpos < 8'd3 || fpos < 8'd3 + flen) fcrc <= crc_byte(fcrc, byte_in);
            if (fpos >= 8'd3 && fpos == 8'd3 + flen + 8'd1) begin    // last CRC byte
              if ({fsh[14:7], byte_in} == {fcrc[15:8], fcrc[7:0]} && 16'(flen) + 3 <= RXMAX) begin
                rx_ok <= 1'b1; rx_last <= rx_work;
              end else begin
                rx_bad <= 1'b1; rx_crc_err <= rx_crc_err + 1'b1;
              end
              fst <= F_WAIT; rbuild <= 5'd1;
            end
          end
        end
        F_RESP: begin
          if (rise) r_armed <= 1'b1;
          if (fall && r_armed) begin
            rbits <= rbits + 1'b1;
            if (rbits == 8'(8 * RESP_LEN - 1)) begin fst <= F_WAIT; up_t <= 1'b1; end
            else begin rsh <= {rsh[8*RESP_LEN-2:0], 1'b0}; up_o <= rsh[8*RESP_LEN-2]; end
          end
        end
        default: ;                                                  // F_WAIT: until idle
      endcase
      if (fst == F_RESP && rbits == 0 && !(fall && r_armed)) up_o <= rsh[8*RESP_LEN-1];
    end
  end
endmodule
