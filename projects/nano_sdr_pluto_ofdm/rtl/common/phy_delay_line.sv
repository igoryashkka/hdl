// Module : phy_delay_line   valid-gated sample delay of DEPTH valid-samples (RAM, read-first with 1-step prefetch).
// On every in_valid the module stores in_data and presents x[n-DEPTH] on out_data one clock later (registered); out_data is 0
// until DEPTH samples have been seen. Between valid pulses nothing changes. DEPTH >= 4.
// Memory: DEPTH x W (BRAM / LUTRAM inferred; the read data register is the RAM output register: no logic in front of it).
// Verification: through tb_phy_sync_sc (bit-exact system test of the detector).
module phy_delay_line #(
  parameter int W     = 32,
  parameter int DEPTH = 1024
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         in_valid,
  input  logic [W-1:0] in_data,
  output logic [W-1:0] out_data
);
  localparam int AW = $clog2(DEPTH);
  logic [W-1:0]  ram [DEPTH] = '{default: '0};
  logic [AW-1:0] ptr = '0;
  logic          primed = 1'b0;
  logic [W-1:0]  rd_q = '0;
  wire  [AW-1:0] ptr_n = (ptr == AW'(DEPTH - 1)) ? '0 : ptr + 1'b1;

  always_ff @(posedge clk) begin
    if (in_valid) begin
      ram[ptr] <= in_data;
      rd_q     <= ram[ptr_n];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ptr <= '0; primed <= 1'b0; out_data <= '0;
    end else if (in_valid) begin
      ptr      <= ptr_n;
      out_data <= primed ? rd_q : '0;
      if (ptr == AW'(DEPTH - 1)) primed <= 1'b1;
    end
  end
endmodule
