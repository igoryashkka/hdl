// Module : phy_cp_insert   frame buffer that (a) re-orders the bit-reversed IFFT stream (BITREV=1) and (b) prepends the
//          cyclic prefix: reads the last CP samples first, then all N samples (N+CP per symbol).
//          With CP=0, BITREV=1 it is also the FFT output reorder buffer of the RX.
// Write side: no backpressure (the IFFT core cannot stall). The producer must only start a frame while frame_ok=1
//          (a free bank exists); `overflow` latches if a frame starts with no free bank (that frame is dropped).
// Read side: out_valid/out_ready, out_first/out_last per symbol (N+CP samples). sym_done pulses when the last sample of
//          a symbol is accepted; frame_written pulses when a frame has been completely stored.
// Memory: NB banks (default 3) x N x (2*IQ_W) bits (BRAM). NB=3 is required for gap-free TX playback behind the SDF IFFT
//         (frame i is delivered while frame i+1 is fed: at the end of feed i, frame i-1 is complete, i-2 may still play). The first sample is readable 2 cycles after the frame's last write.
// Golden: python/tx_ref.py::cp_insert (bit-exact).
module phy_cp_insert
  import phy_pkg::*;
#(
  parameter int N_LOG  = $clog2(FFT_SIZE),
  parameter int CP     = CP_LEN,
  parameter bit BITREV = 1'b1,
  parameter int NB     = 3
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   frame_ok,
  output logic                   frame_written,
  output logic                   sym_done,
  output logic                   overflow,
  output logic                   out_valid,
  input  logic                   out_ready,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im,
  output logic                   out_first,
  output logic                   out_last
);
  localparam int N   = 1 << N_LOG;
  localparam int SYM = N + CP;
  localparam int AW  = $clog2(NB * N);
  localparam int BKW = (NB > 1) ? $clog2(NB) : 1;
  localparam int RW  = $clog2(SYM);

  logic [2*IQ_W-1:0] mem [NB * N];

  // ---------------------------------------------------------------- write
  logic [N_LOG-1:0] wr_idx;
  logic [BKW-1:0]   wr_bank;
  logic [AW-1:0]    wr_base;
  logic [NB-1:0]    full;
  logic             wr_drop;
  assign frame_ok = ~full[wr_bank];

  function automatic logic [N_LOG-1:0] bitrev(input logic [N_LOG-1:0] x);
    logic [N_LOG-1:0] r;
    for (int i = 0; i < N_LOG; i++) r[i] = x[N_LOG-1-i];
    return r;
  endfunction

  wire [N_LOG-1:0] wr_off   = BITREV ? bitrev(wr_idx) : wr_idx;
  wire [AW-1:0]    wr_addr  = wr_base + AW'(wr_off);
  wire             wr_first = (wr_idx == '0);
  wire             wr_ok    = ~wr_drop & ~(wr_first & full[wr_bank]);

  always_ff @(posedge clk) begin
    if (in_valid && wr_ok) mem[wr_addr] <= {in_re, in_im};
  end

  // ---------------------------------------------------------------- read
  logic [RW-1:0]   rd_cnt;
  logic [BKW-1:0]  rd_bank;
  logic [AW-1:0]   rd_base;
  wire             rd_adv = full[rd_bank] && (!out_valid || out_ready);
  logic [N_LOG-1:0] rd_off;
  always_comb begin
    if (int'(rd_cnt) < CP) rd_off = N_LOG'(N - CP + int'(rd_cnt));
    else                   rd_off = N_LOG'(int'(rd_cnt) - CP);
  end
  wire [AW-1:0]     rd_addr = rd_base + AW'(rd_off);

  // synchronous read straight into the output register (no reset / no logic between RAM and register -> BRAM)
  always_ff @(posedge clk) begin
    if (rd_adv) {out_re, out_im} <= mem[rd_addr];
  end

  always_ff @(posedge clk) begin
    frame_written <= 1'b0;
    sym_done      <= 1'b0;
    if (rst) begin
      wr_idx <= '0; wr_bank <= '0; wr_base <= '0; full <= '0; wr_drop <= 1'b0; overflow <= 1'b0;
      rd_cnt <= '0; rd_bank <= '0; rd_base <= '0;
      out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0;
    end else begin
      if (in_valid) begin
        if (wr_first && full[wr_bank]) begin wr_drop <= 1'b1; overflow <= 1'b1; end
        if (wr_idx == N_LOG'(N - 1)) begin
          wr_idx  <= '0;
          wr_drop <= 1'b0;
          if (wr_ok) begin
            full[wr_bank] <= 1'b1; frame_written <= 1'b1;
            if (wr_bank == BKW'(NB - 1)) begin wr_bank <= '0; wr_base <= '0; end
            else begin wr_bank <= wr_bank + 1'b1; wr_base <= wr_base + AW'(N); end
          end
        end else wr_idx <= wr_idx + 1'b1;
      end
      if (rd_adv) begin
        out_valid <= 1'b1;
        out_first <= (rd_cnt == '0);
        out_last  <= (rd_cnt == RW'(SYM - 1));
        if (rd_cnt == RW'(SYM - 1)) begin
          rd_cnt <= '0; full[rd_bank] <= 1'b0;
          if (rd_bank == BKW'(NB - 1)) begin rd_bank <= '0; rd_base <= '0; end
          else begin rd_bank <= rd_bank + 1'b1; rd_base <= rd_base + AW'(N); end
        end else rd_cnt <= rd_cnt + 1'b1;
      end else if (out_valid && out_ready) begin
        out_valid <= 1'b0;
      end
      if (out_valid && out_ready && out_last) sym_done <= 1'b1;
    end
  end
endmodule
