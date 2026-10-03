// Module : phy_rx_window   FFT window gating (CP removal) + IFFT/FFT flush.
// After arm (start index w0, number of windows nwin = 1 LTS + K data symbols) the stream samples with index
//   w0 + k*SYM ... w0 + k*SYM + N - 1   (k = 0 .. nwin-1)
// are passed (index = number of valid input samples since reset, shared with phy_sync_sc so both count the same samples),
// everything else (cyclic prefix, gaps) is dropped. One symbol period after the start of the last window (i.e. where window
// nwin would begin) N-1 zero samples, one per input valid (the empty window nwin), flush the SDF FFT, then `done` pulses.
// Pacing the flush like a real window keeps the arrival rate of the last frame equal to the others (a fast flush would
// deliver two frames back-to-back and overrun the phase tracker). `late` pulses if w0 is already in the past when armed (arm ignored).
// Latency: 1 cycle (registered output).  out_win = window number of the sample.  Index counter is 32 bit (wraps, compared
// with equality / signed difference).
module phy_rx_window
  import phy_pkg::*;
#(
  parameter int N   = FFT_SIZE,
  parameter int SYM = SYMBOL_LEN
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   arm_valid,
  input  logic [31:0]            arm_w0,
  input  logic [7:0]             arm_nwin,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_i,
  input  logic signed [IQ_W-1:0] in_q,
  output logic                   out_valid,
  output logic signed [IQ_W-1:0] out_i,
  output logic signed [IQ_W-1:0] out_q,
  output logic                   out_first,
  output logic                   out_last,
  output logic [7:0]             out_win,
  output logic                   busy,
  output logic                   late,
  output logic                   done
);
  localparam int LATENCY = 1;
  typedef enum logic [2:0] {S_IDLE, S_ARMED, S_WIN, S_GAP, S_FLUSH} st_t;
  st_t          st;
  logic [31:0]  n;                  // index of the next input sample
  logic [31:0]  next_start;
  logic [7:0]   nwin, win;
  logic         final_q;                 // last window passed: wait for the flush trigger
  logic [$clog2(N)-1:0] wcnt;
  logic [$clog2(N):0]   fcnt;

  assign busy = (st != S_IDLE);

  wire at_start = in_valid && (st == S_ARMED || st == S_GAP) && (n == next_start);
  wire starting = at_start && !final_q;
  wire in_win   = in_valid && (st == S_WIN);
  wire pass     = starting || in_win;
  wire [$clog2(N)-1:0] cur_w = starting ? '0 : wcnt;
  wire [7:0]           cur_win = starting ? ((st == S_ARMED) ? 8'd0 : win + 8'd1) : win;
  wire signed [31:0]   w0_dist = $signed(arm_w0 - (n + 32'(in_valid)));

  always_ff @(posedge clk) begin
    late <= 1'b0;
    done <= 1'b0;
    if (rst) begin
      st <= S_IDLE; n <= '0; next_start <= '0; nwin <= '0; win <= '0; wcnt <= '0; fcnt <= '0; final_q <= 1'b0;
      out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0; out_win <= '0;
    end else begin
      out_valid <= 1'b0;
      if (in_valid) n <= n + 1'b1;
      case (st)
        S_IDLE: if (arm_valid) begin
          if (w0_dist < 0) late <= 1'b1;
          else begin st <= S_ARMED; next_start <= arm_w0; nwin <= arm_nwin; final_q <= 1'b0; end
        end
        S_FLUSH: if (in_valid) begin               // zeros paced at the sample rate (= the empty window nwin)
          out_valid <= 1'b1; out_i <= '0; out_q <= '0; out_first <= 1'b0; out_last <= 1'b0;
          fcnt <= fcnt + 1'b1;
          if (fcnt == ($bits(fcnt))'(N - 2)) begin st <= S_IDLE; done <= 1'b1; end
        end
        default: ;
      endcase
      if (at_start && final_q) begin st <= S_FLUSH; fcnt <= '0; final_q <= 1'b0; end
      if (pass) begin
        out_valid <= 1'b1; out_i <= in_i; out_q <= in_q;
        out_first <= (cur_w == '0);
        out_last  <= (cur_w == ($bits(cur_w))'(N - 1));
        out_win   <= cur_win;
        win       <= cur_win;
        wcnt      <= cur_w + 1'b1;
        if (starting) begin st <= S_WIN; next_start <= next_start + 32'(SYM); end
        if (cur_w == ($bits(cur_w))'(N - 1)) begin
          st <= S_GAP;
          if (32'(cur_win) + 32'd1 == 32'(nwin)) final_q <= 1'b1;
        end
      end
    end
  end
endmodule
