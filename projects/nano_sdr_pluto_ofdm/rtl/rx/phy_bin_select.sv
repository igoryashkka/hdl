// Module : phy_bin_select   natural-order FFT frame (FFT_SIZE bins) -> stream of the NUM_ACTIVE_SC active bins in stream order
//   (bins 1..600 then 1448..2047, DC / guard bins dropped).  in_first marks bin 0 of each frame.
//   out_first = active index 0, out_last = active index 1199, out_pilot = pilot slot (index % 12 == PILOT_OFFSET).
// Valid-only (no backpressure), latency 1.   Golden: python/rx_fixed_ref.py::select_active (+ ofdm_ref pilot rule)
module phy_bin_select
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic                   out_pilot,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 1;
  localparam int BW = $clog2(FFT_SIZE);
  logic [BW-1:0] cnt;
  logic [3:0]    pmod;
  wire  [BW-1:0] cur    = in_first ? '0 : cnt;
  wire  [3:0]    cur_pm = in_first ? 4'd0 : pmod;
  wire           active = (cur >= BW'(1) && cur <= BW'(NUM_POS_SC)) || (cur >= BW'(NEG_FIRST_BIN));

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= '0; pmod <= '0; out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0; out_pilot <= 1'b0;
    end else begin
      out_valid <= in_valid & active;
      if (in_valid) begin
        cnt  <= cur + 1'b1;
        pmod <= active ? ((cur_pm == 4'(PILOT_SPACING - 1)) ? 4'd0 : cur_pm + 1'b1) : cur_pm;
        out_first <= (cur == BW'(1));
        out_last  <= (cur == BW'(FFT_SIZE - 1));
        out_pilot <= (cur_pm == 4'(PILOT_OFFSET));
      end
    end
    if (in_valid) begin out_re <= in_re; out_im <= in_im; end
  end
endmodule
