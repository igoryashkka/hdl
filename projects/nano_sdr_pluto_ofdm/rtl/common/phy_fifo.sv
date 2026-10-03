// Module : phy_fifo   synchronous first-word-fall-through FIFO, DEPTH entries (power of two), registered flags.
// wr_ready = not full, rd_valid = not empty; rd_data is valid whenever rd_valid (show-ahead).
// count = number of stored words. Writes while full / reads while empty are ignored (and never lose stored data).
// Latency: data written at cycle t is visible at rd_data at t+1. Throughput 1 word/cycle each side.
// Memory: distributed RAM / BRAM inferred.   Verification: exercised in tb_phy_tx_top (and tb_phy_fifo).
module phy_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 8
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 wr_valid,
  output logic                 wr_ready,
  input  logic [W-1:0]         wr_data,
  output logic                 rd_valid,
  input  logic                 rd_ready,
  output logic [W-1:0]         rd_data,
  output logic [$clog2(DEPTH):0] count
);
  localparam int AW = $clog2(DEPTH);
  logic [W-1:0]  mem [DEPTH];
  logic [AW-1:0] wp, rp;

  assign wr_ready = (count != (AW+1)'(DEPTH));
  assign rd_valid = (count != '0);
  assign rd_data  = mem[rp];

  wire do_wr = wr_valid && wr_ready;
  wire do_rd = rd_valid && rd_ready;

  always_ff @(posedge clk) begin
    if (do_wr) mem[wp] <= wr_data;
    if (rst) begin
      wp <= '0; rp <= '0; count <= '0;
    end else begin
      if (do_wr) wp <= wp + 1'b1;
      if (do_rd) rp <= rp + 1'b1;
      count <= count + (do_wr ? 1'b1 : 1'b0) - (do_rd ? 1'b1 : 1'b0);
    end
  end
endmodule
