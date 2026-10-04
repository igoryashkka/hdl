// Module : phy_rssi_code   40 bit energy -> 16 bit log2 code {pos[5:0], mant[9:0]} (pos = index of the leading one, mant = the 10 bits
//   below it; 0 for input 0).  Power[dB] = 10*log10(2^pos * (1 + mant/1024)) + const.   Latency 3 cycles after `in_valid`.
//   Golden: python/sync_ref.py::rssi_code.
module phy_rssi_code (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,
  input  logic [39:0] in_r,
  output logic        out_valid,
  output logic [15:0] code
);
  logic [39:0] r1, r2;
  logic [5:0]  pos1, pos2;
  logic        v1, v2, z1, z2;
  always_ff @(posedge clk) begin
    if (rst) begin v1 <= 1'b0; v2 <= 1'b0; out_valid <= 1'b0; code <= '0; end
    else begin
      v1 <= in_valid; r1 <= in_r;
      pos1 <= '0;
      for (int b = 0; b < 40; b++) if (in_r[b]) pos1 <= 6'(b);
      z1 <= (in_r == 40'd0);
      v2 <= v1; r2 <= r1; pos2 <= pos1; z2 <= z1;
      out_valid <= v2;
      if (v2) code <= z2 ? 16'd0 : {pos2, 10'((r2 << (6'd39 - pos2)) >> 29)};
    end
  end
endmodule
