// ***************************************************************************
// GFSK RX packet engine for the block design: IQ from rx_fir_decimator -> decoded
// frame records on a 64-bit AXI-stream (to axi_dmac stream source).
//   gfsk_rx_1ch  : mix, decimate, filter, discriminate, bit sync, sync/whitening
//   gfsk_pkt_out : CRC8/CRC16, record build, stream output
// Single channel for now: phase_inc selects the channel, (fc - LO) / fs * 2^32.
//
// Plain Verilog on purpose: Vivado does not accept a SystemVerilog top file as a
// block-design module reference. The SystemVerilog submodules are in the same project.
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_rx_pkt_top (
  input         clk,
  input         rst,
  input         in_valid,
  input  signed [15:0] i_in,
  input  signed [15:0] q_in,
  input         [31:0] phase_inc,
  output        m_axis_valid,
  input         m_axis_ready,
  output [63:0] m_axis_data,
  output        m_axis_last,
  output [15:0] drops
);
  // local reset copy: the AD9361 reset has a large fanout and long routes
  reg rst_r = 1'b1;
  always @(posedge clk) rst_r <= rst;
  wire        frame_start, byte_valid, frame_done;
  wire [7:0]  byte_out, frame_len;

  gfsk_rx_1ch u_rx (
    .clk(clk), .rst(rst_r), .in_valid(in_valid), .i_in(i_in), .q_in(q_in), .phase_inc(phase_inc),
    .frame_start(frame_start), .byte_valid(byte_valid), .byte_out(byte_out),
    .frame_done(frame_done), .frame_len(frame_len)
  );

  gfsk_pkt_out u_pkt (
    .clk(clk), .rst(rst_r), .in_valid(in_valid),
    .frame_start(frame_start), .byte_valid(byte_valid), .byte_out(byte_out),
    .frame_done(frame_done), .frame_len(frame_len),
    .m_axis_valid(m_axis_valid), .m_axis_ready(m_axis_ready), .m_axis_data(m_axis_data),
    .m_axis_last(m_axis_last), .drops(drops)
  );
endmodule
