// ***************************************************************************
// phy_rx_axis_top -- RX-only build wrapper: AD9361 IQ (l_clk domain) -> phy_rx_top (OFDM PHY) -> packets on a 64-bit
// AXI-stream (axi_dmac stream source -> DDR -> C packetizer in the PS), plus an AXI4-Lite register block (control + logging).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Packet record format: see rtl/rx/phy_rx_pkt_out.sv (3 header beats + payload, tlast on the last beat).
// Register map (base address in the BD, 0x7C440000): see rtl/common/phy_regs_axil.v for the generic part.
//   cfg 0x10 NSYMS(8)  0x14 RMIN(32)  0x18 GAIN_SH(4, signed)   (reset values = the module parameters)
//   status snapshot words (write SNAP 0x08, poll bit0, read 0x80 + 4*i):
//     0 {pkt_count[15:0], det_count[15:0]}   1 {wd_count[15:0], drop_count[15:0]}   2 {.., busy, flags[7:0]}
//     3 sample count (in_valid)   4 phy clock count (both since the last clear)    5 {peak|q|, peak|i|} of the ADC samples
//     6 count of ADC samples within 8 LSB of 12-bit full scale   7 {angle[15:0], rssi[15:0]} of the last packet
//     8 evm (sum of pilot L1 errors)   9 cfo_inc   10 n_best   11 {.., seq[15:0]}   12 DMA beats   13 DMA stall clocks
//     14 last sample {q, i}   15 packet counter of the PHY that committed a record (alias of word 0 for diff)
// ADC data: axi_ad9361 adc_data_i0/q0, 16-bit with the 12-bit sample sign-extended.
// ***************************************************************************
`timescale 1ns/100ps

module phy_rx_axis_top #(
  parameter [7:0]  NSYMS   = 8'd2,
  parameter [31:0] RMIN    = 32'd262144,
  parameter [3:0]  GAIN_SH = 4'd0
) (
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF PHY_STREAM" *)   /* keeps l_clk away from the AXI-Lite port (ad_cpu_interconnect picks the S_AXI clock by ASSOCIATED_BUSIF) */
  input         clk,           // AD9361 l_clk
  (* X_INTERFACE_INFO = "xilinx.com:signal:data:1.0 rst DATA" *)    /* plain signal: keeps Vivado from auto-associating it with s_axi_aclk */
  input         rst,
  input         in_valid,      // one pulse per complex sample
  input  signed [15:0] i_in,
  input  signed [15:0] q_in,
  output        m_axis_valid,
  input         m_axis_ready,
  output [63:0] m_axis_data,
  output        m_axis_last,

  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
  input         s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input         s_axi_aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)  input  [11:0] s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input         s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output        s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)   input  [31:0] s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)   input  [3:0]  s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)  input         s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)  output        s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)   output [1:0]  s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)  output        s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)  input         s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)  input  [11:0] s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input         s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output        s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)   output [31:0] s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)   output [1:0]  s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)  output        s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)  input         s_axi_rready
);
  localparam NCFG = 3;
  localparam NST  = 16;

  wire [32*NCFG-1:0] cfg;
  wire               soft_rst, clr;
  wire [32*NST-1:0]  stat;

  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout) + PS soft reset
  always @(posedge clk) rst_r <= rst | soft_rst;

  // ---------------------------------------------------------------- PHY
  wire [15:0] st_det, st_pkt, st_drop, st_wd; wire [7:0] st_flags; wire st_busy;
  wire [15:0] st_rssi, st_angle, st_seq; wire [31:0] st_evm, st_cfo, st_nbest; wire st_pulse;

  phy_rx_top u_phy (
    .clk(clk), .rst(rst_r), .cfg_nsyms(cfg[7:0]), .cfg_rmin(cfg[63:32]), .cfg_gain_sh(cfg[67:64]),
    .in_valid(in_valid), .in_i(i_in), .in_q(q_in),
    .m_axis_valid(m_axis_valid), .m_axis_ready(m_axis_ready), .m_axis_data(m_axis_data), .m_axis_last(m_axis_last),
    .st_det_count(st_det), .st_pkt_count(st_pkt), .st_drop_count(st_drop), .st_wd_count(st_wd), .st_flags(st_flags), .st_busy(st_busy),
    .st_rssi(st_rssi), .st_evm(st_evm), .st_cfo_inc(st_cfo), .st_nbest(st_nbest), .st_angle(st_angle), .st_seq(st_seq), .st_pkt_pulse(st_pulse)
  );

  // ---------------------------------------------------------------- logging counters (phy_clk domain, cleared by `clr`)
  reg [15:0] i_q = 0, q_q = 0; reg v_q = 1'b0;      // register the ADC samples before the logging logic (timing)
  always @(posedge clk) begin i_q <= i_in; q_q <= q_in; v_q <= in_valid; end
  wire [15:0] ai = i_q[15] ? (~i_q + 16'd1) : i_q;
  wire [15:0] aq = q_q[15] ? (~q_q + 16'd1) : q_q;
  wire        clip = (ai >= 16'd2040) || (aq >= 16'd2040);
  reg [31:0] n_samp = 0, n_clk = 0, n_clip = 0, n_beat = 0, n_stall = 0;
  reg [15:0] pk_i = 0, pk_q = 0;
  reg [31:0] last_iq = 0;
  always @(posedge clk) begin
    if (clr || rst_r) begin
      n_samp <= 0; n_clk <= 0; n_clip <= 0; n_beat <= 0; n_stall <= 0; pk_i <= 0; pk_q <= 0;
    end else begin
      n_clk <= n_clk + 1'b1;
      if (in_valid) n_samp <= n_samp + 1'b1;
      if (v_q) begin
        if (ai > pk_i) pk_i <= ai;
        if (aq > pk_q) pk_q <= aq;
        if (clip) n_clip <= n_clip + 1'b1;
        last_iq <= {q_q, i_q};
      end
      if (m_axis_valid && m_axis_ready) n_beat <= n_beat + 1'b1;
      if (m_axis_valid && !m_axis_ready) n_stall <= n_stall + 1'b1;
    end
  end

  assign stat = {
    {st_pkt, st_det},                       // 15 (alias of word 0)
    last_iq,                                // 14
    n_stall, n_beat,                        // 13, 12
    16'd0, st_seq,                          // 11
    st_nbest, st_cfo, st_evm,               // 10, 9, 8
    st_angle, st_rssi,                      // 7
    n_clip,                                 // 6
    pk_q, pk_i,                             // 5
    n_clk, n_samp,                          // 4, 3
    23'd0, st_busy, st_flags,               // 2
    st_wd, st_drop,                         // 1
    st_pkt, st_det                          // 0
  };

  phy_regs_axil #(
    .ID(32'h4F465258), .NCFG(NCFG), .NST(NST),
    .CFG_INIT({{28'd0, GAIN_SH}, RMIN, {24'd0, NSYMS}})
  ) u_regs (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .phy_clk(clk), .cfg_o(cfg), .soft_rst_o(soft_rst), .clr_o(clr), .stat_i(stat)
  );
endmodule
