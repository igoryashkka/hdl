// Module : phy_rx_pkt_out   packet buffer + AXI-stream (64 bit) output towards axi_dmac (stream -> DDR) for the C packetizer.
//   Decoded bytes are written through (wr_en, wr_addr, wr_data); `commit` (with meta data) starts the transfer:
//     beat 0 : {16'hA55A, 8'h02 (record version), flags[7:0], nbytes[15:0], seq[15:0]}
//     beat 1 : {cfo_inc[31:0], n_best[31:0]}          (cfo_inc: NCO phase increment, 2^32 = 2*pi per sample;
//                                                      CFO[Hz] = -inc * fs / 2^32 ;  n_best: sync sample index)
//     beat 2 : {angle[31:16], rssi[15:0], evm[31:0]}  (angle: CPE of the last data symbol, upper 16 bit, 2^16 = 2*pi;
//                                                      rssi: {pos[5:0], mant[9:0]} log2 code of the S-C window energy;
//                                                      evm: sum over the data symbols of the pilot L1 error, see phy_phase_tracker)
//     (record version 3, HDR_V3 = 1: three more beats)
//     beat 3 : {snr_avg[15:0], snr_min[15:0], bad_subcarriers[15:0], noise_code[15:0]}   (codes: log2 * 32, dB = code * 0.0941)
//     beat 4 : {ldpc_fail[7:0], ldpc_iter_max[7:0], ldpc_iter_sum[15:0], mode_bits[7:0], 24'h0}
//     beat 5 : {angle_first[31:0], slope_last[31:0]}   (CPE angle of the first data symbol, phase slope per bin of the last one, 2^32 = 2 pi)
//     payload starts after the last header beat (beat 3 / 6), 8 bytes per beat, first byte in bits [7:0], zero padded; tlast on the final beat.
//   flags: bit0 il_overflow, bit1 tracker overrun, bit2 frame buffer overflow, bit3 late arm (set by the top level).
//   commit while a previous packet is still streaming is dropped (`dropped` counter).
// Handshake: standard AXI-stream valid/ready (output register slice).  Memory: RAM_BYTES x 8 bit (BRAM).
// Throughput: 1 payload beat per 10 cycles.   Verification: tb_phy_rx_pkt_out.
module phy_rx_pkt_out #(
  parameter int RAM_BYTES = 8 * 550,
  parameter bit HDR_V3    = 1'b0          // 1: record version 3 = 5 header beats (adds quality / LDPC statistics beats)
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        wr_en,
  input  logic [12:0] wr_addr,
  input  logic [7:0]  wr_data,
  input  logic        commit,
  input  logic [15:0] c_nbytes,
  input  logic [7:0]  c_flags,
  input  logic [31:0] c_cfo_inc,
  input  logic [31:0] c_nbest,
  input  logic [31:0] c_angle,
  input  logic [15:0] c_rssi,
  input  logic [31:0] c_evm,
  input  logic [63:0] c_b3,
  input  logic [63:0] c_b4,
  input  logic [63:0] c_b5,
  output logic        busy,
  output logic [15:0] dropped,
  output logic [15:0] pkt_count,
  output logic        m_axis_valid,
  input  logic        m_axis_ready,
  output logic [63:0] m_axis_data,
  output logic        m_axis_last
);
  logic [7:0] ram [RAM_BYTES];
  logic [7:0] rd_q;
  logic [12:0] base;
  logic [3:0]  gcnt;
  wire  [12:0] rd_addr = base + 13'(gcnt);
  always_ff @(posedge clk) begin
    if (wr_en) ram[wr_addr] <= wr_data;
    rd_q <= ram[rd_addr];
  end

  typedef enum logic [3:0] {S_IDLE, S_H0, S_H1, S_H2, S_H3, S_H4, S_H5, S_GATHER, S_LOAD} st_t;
  st_t st;
  logic [15:0] nbytes, seq;
  logic [7:0]  flags;
  logic [31:0] cfo_inc, nbest, angle, evm;
  logic [15:0] rssi;
  logic [63:0] asm;
  logic [63:0] b3, b4, b5;

  wire can_load = !m_axis_valid || m_axis_ready;
  assign busy = (st != S_IDLE) || m_axis_valid;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; dropped <= '0; pkt_count <= '0; seq <= '0; m_axis_valid <= 1'b0; m_axis_last <= 1'b0; m_axis_data <= '0;
      base <= '0; gcnt <= '0; asm <= '0;
      nbytes <= '0; flags <= '0; cfo_inc <= '0; nbest <= '0; angle <= '0; rssi <= '0; evm <= '0;
    end else begin
      if (m_axis_valid && m_axis_ready) begin m_axis_valid <= 1'b0; m_axis_last <= 1'b0; end
      if (commit) begin
        if (!busy) begin
          nbytes <= c_nbytes; flags <= c_flags; cfo_inc <= c_cfo_inc; nbest <= c_nbest; angle <= c_angle; rssi <= c_rssi; evm <= c_evm; b3 <= c_b3; b4 <= c_b4; b5 <= c_b5; st <= S_H0;
        end else dropped <= dropped + 1'b1;
      end
      case (st)
        S_H0: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0;
          m_axis_data  <= {16'hA55A, HDR_V3 ? 8'h03 : 8'h02, flags, nbytes, seq};
          st <= S_H1;
        end
        S_H1: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0; m_axis_data <= {cfo_inc, nbest}; st <= S_H2;
        end
        S_H2: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_data <= {angle[31:16], rssi, evm};
          base <= '0; gcnt <= '0;
          if (HDR_V3) begin m_axis_last <= 1'b0; st <= S_H3; end
          else if (nbytes == 16'd0) begin
            m_axis_last <= 1'b1; st <= S_IDLE; seq <= seq + 1'b1; pkt_count <= pkt_count + 1'b1;
          end else begin
            m_axis_last <= 1'b0; st <= S_GATHER;
          end
        end
        S_H3: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0; m_axis_data <= b3; st <= S_H4;
        end
        S_H4: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0; m_axis_data <= b4; st <= S_H5;
        end
        S_H5: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_data <= b5;
          if (nbytes == 16'd0) begin
            m_axis_last <= 1'b1; st <= S_IDLE; seq <= seq + 1'b1; pkt_count <= pkt_count + 1'b1;
          end else begin
            m_axis_last <= 1'b0; st <= S_GATHER;
          end
        end
        S_GATHER: begin
          // address base+gcnt is presented (combinationally) at step gcnt; the byte is in rd_q at step gcnt+1
          if (gcnt >= 4'd1)
            asm[8*(gcnt-1) +: 8] <= (({3'b000, base} + 16'(gcnt) - 16'd1) < nbytes) ? rd_q : 8'd0;
          if (gcnt == 4'd8) begin st <= S_LOAD; gcnt <= '0; end
          else gcnt <= gcnt + 1'b1;
        end
        S_LOAD: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_data <= asm;
          if ({3'b000, base} + 16'd8 >= nbytes) begin
            m_axis_last <= 1'b1; st <= S_IDLE; seq <= seq + 1'b1; pkt_count <= pkt_count + 1'b1;
          end else begin
            m_axis_last <= 1'b0; base <= base + 13'd8; st <= S_GATHER;
          end
        end
        default: ;
      endcase
    end
  end
endmodule
