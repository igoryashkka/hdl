// Module : phy_crc   CRC-32 (IEEE 802.3, reflected), byte-wise, register value without final XOR.
// Latency: 1 cycle; `done` pulses 1 cycle after in_valid&in_last.
// TX use : feed payload; zlib.crc32(payload) == ~crc ; append ~crc LSB-first.
// RX use : feed payload+4 CRC bytes; `ok` (valid at `done`) = (crc == CRC32_RESIDUE).
// Golden : python/crc_ref.py
module phy_crc
  import phy_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        in_valid,
  input  logic        in_first,
  input  logic        in_last,
  input  logic [7:0]  in_data,
  output logic        done,
  output logic [31:0] crc,
  output logic        ok
);
  localparam int LATENCY = 1;

  logic [31:0] reg_q, next_c;

  always_comb begin
    next_c = in_first ? CRC32_INIT : reg_q;
    for (int i = 0; i < 8; i++)
      next_c = (next_c >> 1) ^ (CRC32_POLY_REV & {32{next_c[0] ^ in_data[i]}});
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      reg_q <= CRC32_INIT;
      done  <= 1'b0;
      ok    <= 1'b0;
    end else begin
      done <= in_valid & in_last;
      if (in_valid) begin
        reg_q <= next_c;
        ok    <= (next_c == CRC32_RESIDUE);
      end
    end
  end
  assign crc = reg_q;
endmodule
