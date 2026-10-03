// ***************************************************************************
// phy_rx_axis_top -- RX-only build wrapper: AD9361 IQ (l_clk domain) -> PHY RX -> packets on a
// 64-bit AXI-stream (axi_dmac stream source -> DDR -> C packetizer in PS).
// Plain Verilog on purpose: Vivado needs a Verilog top for a block-design module reference;
// the SystemVerilog PHY blocks (rtl/rx, rtl/common) live in the same project.
//
// SCAFFOLD: the PHY RX chain is not connected yet. Until then this emits a 2-beat heartbeat record
// every 2^HB_BITS valid samples so the PL -> DMA -> PS path can be tested on hardware:
//   beat0 = {32'hOFDM_5258 magic, sample counter[31:0]}   beat1 = {i_in, q_in, drops/flags}
// Packet record format of the real PHY: see STATUS.md (to be defined together with the C packetizer).
// ***************************************************************************
`timescale 1ns/100ps

module phy_rx_axis_top #(
  parameter HB_BITS = 20
) (
  input         clk,           // AD9361 l_clk
  input         rst,
  input         in_valid,      // one pulse per complex sample
  input  signed [15:0] i_in,
  input  signed [15:0] q_in,
  output        m_axis_valid,
  input         m_axis_ready,
  output [63:0] m_axis_data,
  output        m_axis_last,
  output [15:0] drops
);
  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout)
  always @(posedge clk) rst_r <= rst;

  reg [31:0] cnt   = 32'd0;
  reg [1:0]  beat  = 2'd0;                // 0 idle, 1 send beat0, 2 send beat1
  reg [15:0] drop_r = 16'd0;
  reg [31:0] snap  = 32'd0;

  wire hb_hit = in_valid && (cnt[HB_BITS-1:0] == {HB_BITS{1'b1}});

  always @(posedge clk) begin
    if (rst_r) begin
      cnt <= 32'd0; beat <= 2'd0; drop_r <= 16'd0; snap <= 32'd0;
    end else begin
      if (in_valid) cnt <= cnt + 32'd1;
      case (beat)
        2'd0: if (hb_hit) begin snap <= {i_in, q_in}; beat <= 2'd1; end
        2'd1: if (m_axis_ready) beat <= 2'd2;
        2'd2: if (m_axis_ready) beat <= 2'd0;
        default: beat <= 2'd0;
      endcase
      if (hb_hit && beat != 2'd0) drop_r <= drop_r + 16'd1;
    end
  end

  assign m_axis_valid = (beat != 2'd0);
  assign m_axis_data  = (beat == 2'd1) ? {32'h4F46444D, cnt} : {snap, 16'd0, drop_r};
  assign m_axis_last  = (beat == 2'd2);
  assign drops        = drop_r;
endmodule
