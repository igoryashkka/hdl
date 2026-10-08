// Module : phy_interleaver  symbol-level block interleaver / deinterleaver (DEINT=1), ping-pong RAM, word-wide.
// Rotation is applied on the WRITE side (equivalent result) so the read path is a plain synchronous BRAM read.
// One block = NSYM = ROWS*COLS words (one OFDM symbol: 1100 QAM symbols = 4400 coded bits).
//   interleave   : out[m] = rot( in[pi(m)] ) if m odd, pi(m)  = (m % COLS)*ROWS + m / COLS
//   deinterleave : out[i] = unrot( in[m(i)] ) if m(i) odd, m(i) = (i % ROWS)*COLS + i / ROWS
//   rot = circular left rotation by ROT_UNIT bits (1 for hard bits, 8 for 8-bit LLRs in a packed word).
// Interface: in/out valid-ready, out_first/out_last mark block boundaries. Backpressure safe (no loss/dup).
// Latency: block store-and-forward: first output word appears NSYM+2 cycles after the first input word of a block
//          (when the output is ready); steady state throughput 1 word/cycle in and out.
// Memory: 2*NSYM x WORD_W (BRAM inferred, simple dual port).   Golden: python/interleaver_ref.py (bit-exact).
module phy_interleaver
  import phy_pkg::*;
#(
  parameter int WORD_W   = BITS_PER_SYM,
  parameter int ROT_UNIT = 1,
  parameter int ROWS     = IL_ROWS,
  parameter int COLS     = IL_COLS,
  parameter bit DEINT    = 1'b0
) (
  input  logic              clk,
  input  logic              rst,
  input  logic              rot_en,          // 0: no rotation (QPSK words), static per block
  input  logic              in_valid,
  output logic              in_ready,
  input  logic [WORD_W-1:0] in_data,
  output logic              out_valid,
  input  logic              out_ready,
  output logic [WORD_W-1:0] out_data,
  output logic              out_first,
  output logic              out_last
);
  localparam int NSYM   = ROWS * COLS;
  localparam int AW     = $clog2(2 * NSYM);
  localparam int IW     = $clog2(NSYM);
  localparam int FAST_N = DEINT ? ROWS : COLS;   // fast counter modulus of the read address generator
  localparam int STEP   = DEINT ? COLS : ROWS;   // address step of the fast counter

  logic [WORD_W-1:0] mem [2 * NSYM];

  // ---------------------------------------------------------------- write side
  logic [IW-1:0] wr_idx;
  logic          wr_bank;
  logic [1:0]    full;
  assign in_ready = ~full[wr_bank];

  // ---------------------------------------------------------------- read side
  logic [IW-1:0] rd_cnt;          // words read so far in this block
  logic [IW-1:0] rd_addr;         // address inside the block
  logic [IW-1:0] rd_base;         // slow counter value (column start)
  logic [IW-1:0] fast_cnt;
  logic          rd_bank;
  wire           rd_adv = full[rd_bank] && (!out_valid || out_ready);

  function automatic logic [WORD_W-1:0] rotl(input logic [WORD_W-1:0] w);
    return (ROT_UNIT % WORD_W == 0) ? w : {w[WORD_W-1-(ROT_UNIT%WORD_W):0], w[WORD_W-1:WORD_W-(ROT_UNIT%WORD_W)]};
  endfunction
  function automatic logic [WORD_W-1:0] rotr(input logic [WORD_W-1:0] w);
    return (ROT_UNIT % WORD_W == 0) ? w : {w[(ROT_UNIT%WORD_W)-1:0], w[WORD_W-1:(ROT_UNIT%WORD_W)]};
  endfunction

  logic [AW-1:0]     rd_phys;
  assign rd_phys = AW'(rd_addr) + (rd_bank ? AW'(NSYM) : '0);

  // write side: position of the word in the output block decides the rotation
  //   interleave   : word i lands at output index m = pi_inv(i) = (i % ROWS)*COLS + i / ROWS -> rotl when m odd
  //   deinterleave : word i is stored at address i (= m)                                    -> rotr when i odd
  logic [IW-1:0] wfast, wslow;           // i % ROWS , i / ROWS   (interleave only)
  wire           m_odd_w = DEINT ? wr_idx[0] : ((wfast[0] & COLS[0]) ^ wslow[0]);
  wire [WORD_W-1:0] wdata = (m_odd_w && rot_en) ? (DEINT ? rotr(in_data) : rotl(in_data)) : in_data;

  always_ff @(posedge clk) begin
    if (in_valid && in_ready)
      mem[wr_bank ? (AW'(NSYM) + AW'(wr_idx)) : AW'(wr_idx)] <= wdata;
  end

  // read side: synchronous read directly into the output data register (no reset, no logic)
  always_ff @(posedge clk) begin
    if (rd_adv) out_data <= mem[rd_phys];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_idx <= '0; wr_bank <= 1'b0; full <= 2'b00;
      rd_cnt <= '0; rd_addr <= '0; rd_base <= '0; fast_cnt <= '0; rd_bank <= 1'b0;
      out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0;
      wfast <= '0; wslow <= '0;
    end else begin
      // write pointer / full set
      if (in_valid && in_ready) begin
        if (wfast == IW'(ROWS - 1)) begin wfast <= '0; wslow <= wslow + 1'b1; end else wfast <= wfast + 1'b1;
        if (wr_idx == IW'(NSYM - 1)) begin
          wfast <= '0; wslow <= '0;
          wr_idx <= '0; full[wr_bank] <= 1'b1; wr_bank <= ~wr_bank;
        end else wr_idx <= wr_idx + 1'b1;
      end
      // read side
      if (rd_adv) begin
        out_valid <= 1'b1;
        out_first <= (rd_cnt == '0);
        out_last  <= (rd_cnt == IW'(NSYM - 1));
        if (rd_cnt == IW'(NSYM - 1)) begin
          rd_cnt <= '0; rd_addr <= '0; rd_base <= '0; fast_cnt <= '0;
          full[rd_bank] <= 1'b0; rd_bank <= ~rd_bank;
        end else begin
          rd_cnt <= rd_cnt + 1'b1;
          if (fast_cnt == IW'(FAST_N - 1)) begin
            fast_cnt <= '0; rd_base <= rd_base + 1'b1; rd_addr <= rd_base + 1'b1;
          end else begin
            fast_cnt <= fast_cnt + 1'b1; rd_addr <= rd_addr + IW'(STEP);
          end
        end
      end else if (out_valid && out_ready) begin
        out_valid <= 1'b0;
      end
    end
  end
endmodule
