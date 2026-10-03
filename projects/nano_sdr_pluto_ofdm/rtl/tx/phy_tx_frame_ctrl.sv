// Module : phy_tx_frame_ctrl   TX frame sequencer: preamble (sync, LTS) + nsyms data symbols + IFFT flush + soft reset.
// Frame = [sync][LTS][data 0 .. data nsyms-1]; every symbol goes through the IFFT and is transmitted (N+CP samples).
// Rules implemented here (see STATUS.md "TX timing"):
//   * credit: symbol i is started only while (i - symbols fully played) <= NB-1 (NB = frame-buffer banks).
//     The SDF IFFT delivers frame i from the END of its feed until the end of feed i+1, so a free bank is needed
//     when feed i ends (bank of frame i-NB must be free); with NB=3 playback stays gap-free (51 us slack at 20 MHz+ clocks);
//   * after the last symbol N-1 zero samples flush the IFFT; when all symbols of the packet are written to the
//     frame buffer the IFFT core is soft-reset (stage counters realigned for the next packet).
// Interface: go_valid/go_ready (+ go_nsyms), pre_*/map_* start handshakes (see those modules), sym_end pulse from the
//   IFFT input mux (last bin of a symbol), flush_valid (zero samples), fft_rst, pkt_done pulse.
// Latency: none (control). Verification: tb_phy_tx_top (system) + start/flush counts checked by the Python model.
module phy_tx_frame_ctrl
  import phy_pkg::*;
#(
  parameter int NB = 3              // number of frame-buffer banks (phy_cp_insert NB)
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       go_valid,
  output logic       go_ready,
  input  logic [7:0] go_nsyms,
  output logic       pre_start_valid,
  input  logic       pre_start_ready,
  output logic       pre_start_kind,
  output logic       map_start_valid,
  input  logic       map_start_ready,
  input  logic       sym_end,
  output logic       flush_valid,
  input  logic       frame_written,
  input  logic       sym_done,
  output logic       fft_rst,
  output logic       pkt_done,
  output logic       active
);
  typedef enum logic [2:0] {S_IDLE, S_CREDIT, S_START, S_RUN, S_FLUSH, S_DRAIN, S_RST} state_t;
  state_t state;

  logic [8:0]  total;                 // nsyms + 2
  logic [8:0]  idx;                   // symbol index within the packet
  logic [8:0]  fw_cnt;                // frames written in this packet
  logic [3:0]  started, done_cnt;
  logic [$clog2(FFT_SIZE):0] flush_cnt;
  logic [1:0]  rst_cnt;

  wire [3:0] inflight = started - done_cnt;
  wire       is_pre   = (idx < 9'd2);

  assign go_ready        = (state == S_IDLE);
  assign active          = (state != S_IDLE);
  assign pre_start_valid = (state == S_START) && is_pre;
  assign pre_start_kind  = (idx == 9'd1);
  assign map_start_valid = (state == S_START) && !is_pre;
  assign flush_valid     = (state == S_FLUSH);
  assign fft_rst         = (state == S_RST);

  always_ff @(posedge clk) begin
    pkt_done <= 1'b0;
    if (rst) begin
      state <= S_IDLE; total <= '0; idx <= '0; fw_cnt <= '0; started <= '0; done_cnt <= '0;
      flush_cnt <= '0; rst_cnt <= '0;
    end else begin
      if (sym_done) done_cnt <= done_cnt + 1'b1;
      if (frame_written) fw_cnt <= fw_cnt + 1'b1;
      case (state)
        S_IDLE: if (go_valid) begin
          total <= {1'b0, go_nsyms} + 9'd2; idx <= '0; fw_cnt <= '0; state <= S_CREDIT;
        end
        S_CREDIT: if (inflight <= 4'(NB - 1)) state <= S_START;
        S_START: begin
          if (is_pre ? pre_start_ready : map_start_ready) begin
            started <= started + 1'b1; state <= S_RUN;
          end
        end
        S_RUN: if (sym_end) begin
          idx <= idx + 1'b1;
          if (idx + 1'b1 == total) begin state <= S_FLUSH; flush_cnt <= '0; end
          else state <= S_CREDIT;
        end
        S_FLUSH: begin
          flush_cnt <= flush_cnt + 1'b1;
          if (flush_cnt == ($bits(flush_cnt))'(FFT_SIZE - 2)) state <= S_DRAIN;
        end
        S_DRAIN: if (fw_cnt == total) begin state <= S_RST; rst_cnt <= '0; end
        S_RST: begin
          rst_cnt <= rst_cnt + 1'b1;
          if (rst_cnt == 2'd2) begin state <= S_IDLE; pkt_done <= 1'b1; end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
