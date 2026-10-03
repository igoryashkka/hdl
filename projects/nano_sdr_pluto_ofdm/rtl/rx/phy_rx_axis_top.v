// ***************************************************************************
// phy_rx_axis_top -- RX-only build wrapper: AD9361 IQ (l_clk domain) -> phy_rx_top (OFDM PHY) -> packets on a 64-bit
// AXI-stream (axi_dmac stream source -> DDR -> C packetizer in the PS).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Packet record format: see rtl/rx/phy_rx_pkt_out.sv (3 header beats + payload, tlast on the last beat).
// Configuration (parameters; a register interface can replace them later):
//   NSYMS  number of OFDM data symbols per packet (payload = NSYMS * 550 bytes), must match the transmitter
//   RMIN   detector energy gate (|P| and energy in units of the 8-bit-scaled window sum; ~ -16 dB below nominal level)
//   GAIN_SH digital gain shift before the detector (AGC hook)
// ADC data: axi_ad9361 adc_data_i0/q0, 16-bit with the 12-bit sample sign-extended.
// ***************************************************************************
`timescale 1ns/100ps

module phy_rx_axis_top #(
  parameter [7:0]  NSYMS   = 8'd2,
  parameter [31:0] RMIN    = 32'd262144,
  parameter signed [3:0] GAIN_SH = 4'sd0
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
  output [15:0] status_det_count,
  output [15:0] status_pkt_count,
  output [15:0] status_drop_count,
  output [15:0] status_wd_count,
  output [7:0]  status_flags,
  output        status_busy
);
  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout)
  always @(posedge clk) rst_r <= rst;

  phy_rx_top u_phy (
    .clk(clk), .rst(rst_r), .cfg_nsyms(NSYMS), .cfg_rmin(RMIN), .cfg_gain_sh(GAIN_SH),
    .in_valid(in_valid), .in_i(i_in), .in_q(q_in),
    .m_axis_valid(m_axis_valid), .m_axis_ready(m_axis_ready), .m_axis_data(m_axis_data), .m_axis_last(m_axis_last),
    .st_det_count(status_det_count), .st_pkt_count(status_pkt_count), .st_drop_count(status_drop_count),
    .st_wd_count(status_wd_count), .st_flags(status_flags), .st_busy(status_busy)
  );
endmodule
