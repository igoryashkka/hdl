// Module : phy_rx_pkt_out   packet buffer + AXI-stream (64 bit) output towards axi_dmac (stream -> DDR) for the C packetizer.
//   Decoded bytes are written through (wr_en, wr_addr, wr_data); `commit` (with meta data) starts the transfer:
//     beat 0 : {16'hA55A, 8'h01 (record version), flags[7:0], nbytes[15:0], seq[15:0]}
//     beat 1 : {cfo_inc[31:0], n_best[31:0]}          (cfo_inc: NCO phase increment, 2^32 = 2*pi per sample;
//                                                      CFO[Hz] = -inc * fs / 2^32 ;  n_best: sync sample index)
//     beat 2 : {angle[31:0], 32'hFFFF_FFFF}           (angle: CPE of the last data symbol, 2^32 = 2*pi; reserved word)
//     beat 3 .. : payload, 8 bytes per beat, first byte in bits [7:0], zero padded; tlast on the final beat.
//   flags: bit0 il_overflow, bit1 tracker overrun, bit2 frame buffer overflow, bit3 late arm (set by the top level).
//   commit while a previous packet is still streaming is dropped (`dropped` counter).
// Handshake: standard AXI-stream valid/ready (output register slice).  Memory: RAM_BYTES x 8 bit (BRAM).
// Throughput: 1 payload beat per 10 cycles.   Verification: tb_phy_rx_pkt_out.
module phy_rx_pkt_out #(
  parameter int RAM_BYTES = 8 * 550
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

  typedef enum logic [2:0] {S_IDLE, S_H0, S_H1, S_H2, S_GATHER, S_LOAD} st_t;
  st_t st;
  logic [15:0] nbytes, seq;
  logic [7:0]  flags;
  logic [31:0] cfo_inc, nbest, angle;
  logic [63:0] asm;

  wire can_load = !m_axis_valid || m_axis_ready;
  assign busy = (st != S_IDLE) || m_axis_valid;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; dropped <= '0; pkt_count <= '0; seq <= '0; m_axis_valid <= 1'b0; m_axis_last <= 1'b0; m_axis_data <= '0;
      base <= '0; gcnt <= '0; asm <= '0;
      nbytes <= '0; flags <= '0; cfo_inc <= '0; nbest <= '0; angle <= '0;
    end else begin
      if (m_axis_valid && m_axis_ready) begin m_axis_valid <= 1'b0; m_axis_last <= 1'b0; end
      if (commit) begin
        if (!busy) begin
          nbytes <= c_nbytes; flags <= c_flags; cfo_inc <= c_cfo_inc; nbest <= c_nbest; angle <= c_angle; st <= S_H0;
        end else dropped <= dropped + 1'b1;
      end
      case (st)
        S_H0: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0;
          m_axis_data  <= {16'hA55A, 8'h01, flags, nbytes, seq};
          st <= S_H1;
        end
        S_H1: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_last <= 1'b0; m_axis_data <= {cfo_inc, nbest}; st <= S_H2;
        end
        S_H2: if (can_load) begin
          m_axis_valid <= 1'b1; m_axis_data <= {angle, 32'hFFFF_FFFF};
          base <= '0; gcnt <= '0;
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
