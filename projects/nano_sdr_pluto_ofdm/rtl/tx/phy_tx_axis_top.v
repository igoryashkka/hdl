// ***************************************************************************
// phy_tx_axis_top -- TX-only build wrapper: packets from the PS (axi_dmac, memory -> AXI-stream, 64-bit)
//   -> phy_tx_top (OFDM PHY) -> IQ to the AD9361 DAC interface (l_clk domain, pulled by dac_valid).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Stream format: each packet is one DMA transfer; 64-bit beats are serialised LSB byte first; tlast of the last beat
// ends the packet. The payload length must be a multiple of 8 bytes (DMA beat); the PHY zero-pads it to a multiple of
// 550 bytes (one OFDM symbol, BYTES_PER_OFDM) -- the C packetizer must carry its own length/CRC inside the payload.
// Gain: Q2.14 digital TX gain (16384 = 1.0), constant here; a register interface can be added later.
// Status outputs (overflow/underflow/trunc/busy) are left for an ILA/GPIO hookup.
// ***************************************************************************
`timescale 1ns/100ps

module phy_tx_axis_top #(
  parameter [15:0] GAIN = 16'd16384
) (
  input         clk,           // AD9361 l_clk
  input         rst,
  input         s_axis_valid,
  output        s_axis_ready,
  input  [63:0] s_axis_data,
  input         s_axis_last,
  input         dac_valid,     // core requests one sample
  output [15:0] dac_data_i,
  output [15:0] dac_data_q,
  output        dac_dunf,
  output        status_overflow,
  output        status_trunc,
  output        status_busy
);
  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout)
  always @(posedge clk) rst_r <= rst;

  // ---- 64 -> 8 bit serialiser -------------------------------------------------------
  reg [63:0] word  = 64'd0;
  reg        wlast = 1'b0;
  reg [3:0]  left  = 4'd0;               // bytes left in `word`
  wire       phy_ready;
  wire       byte_valid = (left != 4'd0);
  wire       byte_take  = byte_valid && phy_ready;

  assign s_axis_ready = (left == 4'd0);

  always @(posedge clk) begin
    if (rst_r) begin
      left <= 4'd0; word <= 64'd0; wlast <= 1'b0;
    end else begin
      if (s_axis_valid && s_axis_ready) begin
        word <= s_axis_data; wlast <= s_axis_last; left <= 4'd8;
      end else if (byte_take) begin
        word <= {8'd0, word[63:8]};
        left <= left - 4'd1;
      end
    end
  end

  wire        pkt_done;
  wire [15:0] iq_re, iq_im;
  wire        iq_valid, underflow;

  phy_tx_top u_phy (
    .clk(clk), .rst(rst_r), .gain(GAIN),
    .s_valid(byte_valid), .s_ready(phy_ready), .s_data(word[7:0]), .s_last(wlast && (left == 4'd1)),
    .iq_pull(dac_valid), .iq_re(iq_re), .iq_im(iq_im), .iq_valid(iq_valid),
    .underflow(underflow), .overflow(status_overflow), .pkt_trunc(status_trunc), .pkt_done(pkt_done),
    .busy(status_busy)
  );

  assign dac_data_i = iq_re;
  assign dac_data_q = iq_im;
  assign dac_dunf   = underflow;
endmodule
