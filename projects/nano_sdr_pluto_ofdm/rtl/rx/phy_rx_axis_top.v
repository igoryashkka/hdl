// ***************************************************************************
// phy_rx_axis_top -- RX-only build wrapper: AD9361 IQ (l_clk domain) -> phy_rx_top (OFDM PHY) -> packets on a 64-bit
// AXI-stream (axi_dmac stream source -> DDR -> C packetizer in the PS), plus an AXI4-Lite register block (control + logging).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Packet record format: see rtl/rx/phy_rx_pkt_out.sv (3 header beats + payload, tlast on the last beat).
// Register map (base address in the BD, 0x7C440000): see rtl/common/phy_regs_axil.v for the generic part.
//   cfg 0x10 NSYMS(8, data symbols)  0x14 RMIN(32)  0x18 GAIN_SH(4, signed)  0x1C MMSE(bit0) HDR_EN(bit1: mode from the header symbol) UA(bit3: uncertainty-aware LLR) CA(bit4: code-aided second pass, needs parameter CA = 1) MODE(bit2: manual / fallback
//   mode, 0 = MAX RANGE QPSK + LDPC 1/2, 1 = MAX RATE 16-QAM + LDPC 5/6)  0x20 MAX_ITER(5)  0x24 BAD_THR(13, signed)  0x28 FT_EN(bit0) SMOOTH(bit1: smoothing of the channel estimate)  0x2C TAU_TGT(8)
//   (reset values = the module parameters)
//   status snapshot words (write SNAP 0x08, poll bit0, read 0x80 + 4*i):
//     0 {pkt_count[15:0], det_count[15:0]}   1 {wd_count[15:0], drop_count[15:0]}   2 {.., busy, flags[7:0]}
//     3 sample count (in_valid)   4 phy clock count (both since the last clear)    5 {peak|q|, peak|i|} of the ADC samples
//     6 count of ADC samples within 8 LSB of 12-bit full scale   7 {angle[15:0], rssi[15:0]} of the last packet
//     8 evm (sum of pilot L1 errors)   9 cfo_inc   10 n_best   11 {.., seq[15:0]}   12 DMA beats   13 DMA stall clocks
//     14 last sample {q, i}   15 alias of word 0
//     16 {snr_min, snr_avg} codes (log2*32, last packet)  17 {noise_code, bad_subcarriers}  18 {ldpc iter_sum[27:16], iter_max[12:8], fail[7:0]}
//     19 {cwfail_count, cw_count}   20 {w0_adj[31:24], tau_q8[19:0]}   31 feature word {.., mmse, coded}
// ADC data: axi_ad9361 adc_data_i0/q0, 16-bit with the 12-bit sample sign-extended.
// ***************************************************************************
`timescale 1ns/100ps

module phy_rx_axis_top #(
  parameter [7:0]  NSYMS   = 8'd2,
  parameter [31:0] RMIN    = 32'd262144,
  parameter [3:0]  GAIN_SH = 4'd0,
  parameter        CODED   = 1'b1,          // LDPC + MMSE / soft LLR back-end (Zynq-7020 design); 0 = uncoded hard decision
  parameter        MMSE    = 1'b1,
  parameter        HDR_EN  = 1'b1,          // take the PHY mode from the header symbol
  parameter        MODE    = 1'b1,          // manual mode / fallback when the header CRC fails
  parameter [4:0]  MAX_ITER = 5'd10,
  parameter [12:0] BAD_THR = 13'd106,       // bad-subcarrier threshold, SNR code (log2 * 32): 106 = 10 dB
  parameter        UA      = 1'b0,          // uncertainty-aware LLR (Patch A)
  parameter        UA_HW   = 1'b1,          // uncertainty-aware LLR hardware present (0: baseline build)
  parameter        CA      = 1'b0,          // code-aided second pass (Patch B): hardware present and enabled at reset
  parameter        SMOOTH  = 1'b1,          // LTS channel estimate smoothing (3 bins, ~2 dB at low SNR)
  parameter        FT_EN   = 1'b1,          // fine timing loop (window re-centering from the LTS)
  parameter [7:0]  TAU_TGT = 8'd56          // wanted LTS window earliness [samples]
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
  localparam NCFG = 8;
  localparam NST  = 32;

  wire [32*NCFG-1:0] cfg;
  wire               soft_rst, clr;
  wire [32*NST-1:0]  stat;

  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout) + PS soft reset
  always @(posedge clk) rst_r <= rst | soft_rst;

  // ---------------------------------------------------------------- PHY
  wire [15:0] st_det, st_pkt, st_drop, st_wd; wire [7:0] st_flags; wire st_busy;
  wire [15:0] st_rssi, st_angle, st_seq; wire [31:0] st_evm, st_cfo, st_nbest; wire st_pulse;

  wire signed [19:0] st_tau_q8; wire signed [7:0] st_w0_adj; wire st_mode, st_hdr_ok, st_hdr_mism; wire [13:0] st_hdr_conf;
  wire [15:0] st_snr_avg, st_snr_min, st_bad, st_noise, st_cw_count, st_cwfail_count; wire [7:0] st_ldpc_fail; wire [4:0] st_ldpc_imax; wire [11:0] st_ldpc_isum;
  phy_rx_top #(.CODED(CODED), .CA(CA), .UA_HW(UA_HW)) u_phy (
    .clk(clk), .rst(rst_r), .cfg_nsyms(cfg[7:0]), .cfg_rmin(cfg[63:32]), .cfg_gain_sh(cfg[67:64]),
    .cfg_mmse(cfg[96]), .cfg_hdr_en(cfg[97]), .cfg_mode(cfg[98]), .cfg_ua(cfg[99]), .cfg_ca(cfg[100]), .cfg_max_iter(cfg[132:128]), .cfg_bad_thr(cfg[172:160]), .cfg_ft_en(cfg[192]), .cfg_smooth(cfg[193]), .cfg_tau_tgt(cfg[231:224]),
    .in_valid(in_valid), .in_i(i_in), .in_q(q_in),
    .m_axis_valid(m_axis_valid), .m_axis_ready(m_axis_ready), .m_axis_data(m_axis_data), .m_axis_last(m_axis_last),
    .st_det_count(st_det), .st_pkt_count(st_pkt), .st_drop_count(st_drop), .st_wd_count(st_wd), .st_flags(st_flags), .st_busy(st_busy),
    .st_rssi(st_rssi), .st_evm(st_evm), .st_cfo_inc(st_cfo), .st_nbest(st_nbest), .st_angle(st_angle), .st_seq(st_seq), .st_pkt_pulse(st_pulse),
    .st_snr_avg(st_snr_avg), .st_snr_min(st_snr_min), .st_bad(st_bad), .st_noise(st_noise), .st_ldpc_fail(st_ldpc_fail), .st_ldpc_imax(st_ldpc_imax),
    .st_ldpc_isum(st_ldpc_isum), .st_cw_count(st_cw_count), .st_cwfail_count(st_cwfail_count), .st_tau_q8(st_tau_q8), .st_w0_adj(st_w0_adj),
    .st_mode(st_mode), .st_hdr_ok(st_hdr_ok), .st_hdr_mism(st_hdr_mism), .st_hdr_conf(st_hdr_conf)
  );

  // ---------------------------------------------------------------- logging counters (phy_clk domain, cleared by `clr`)
  reg [15:0] i_q = 0, q_q = 0; reg v_q = 1'b0;      // register the ADC samples before the logging logic (timing)
  always @(posedge clk) begin i_q <= i_in; q_q <= q_in; v_q <= in_valid; end
  wire [15:0] ai = i_q[15] ? (~i_q + 16'd1) : i_q;
  wire [15:0] aq = q_q[15] ? (~q_q + 16'd1) : q_q;
  wire        clip_c = (ai >= 16'd2040) || (aq >= 16'd2040);
  reg [15:0] ai_r = 0, aq_r = 0; reg clip = 1'b0, v_r = 1'b0; reg [31:0] iq_r = 0;      // second register stage (timing)
  always @(posedge clk) begin ai_r <= ai; aq_r <= aq; clip <= clip_c; v_r <= v_q; iq_r <= {q_q, i_q}; end
  reg [31:0] n_samp = 0, n_clk = 0, n_clip = 0, n_beat = 0, n_stall = 0;
  reg [15:0] pk_i = 0, pk_q = 0;
  reg [31:0] last_iq = 0;
  always @(posedge clk) begin
    if (clr || rst_r) begin
      n_samp <= 0; n_clk <= 0; n_clip <= 0; n_beat <= 0; n_stall <= 0; pk_i <= 0; pk_q <= 0;
    end else begin
      n_clk <= n_clk + 1'b1;
      if (in_valid) n_samp <= n_samp + 1'b1;
      if (v_r) begin
        if (ai_r > pk_i) pk_i <= ai_r;
        if (aq_r > pk_q) pk_q <= aq_r;
        if (clip) n_clip <= n_clip + 1'b1;
        last_iq <= iq_r;
      end
      if (m_axis_valid && m_axis_ready) n_beat <= n_beat + 1'b1;
      if (m_axis_valid && !m_axis_ready) n_stall <= n_stall + 1'b1;
    end
  end

  wire [31:0] sw [0:NST-1];
  assign sw[0]  = {st_pkt, st_det};
  assign sw[1]  = {st_wd, st_drop};
  assign sw[2]  = {23'd0, st_busy, st_flags};
  assign sw[3]  = n_samp;
  assign sw[4]  = n_clk;
  assign sw[5]  = {pk_q, pk_i};
  assign sw[6]  = n_clip;
  assign sw[7]  = {st_angle, st_rssi};
  assign sw[8]  = st_evm;
  assign sw[9]  = st_cfo;
  assign sw[10] = st_nbest;
  assign sw[11] = {16'd0, st_seq};
  assign sw[12] = n_beat;
  assign sw[13] = n_stall;
  assign sw[14] = last_iq;
  assign sw[15] = {st_pkt, st_det};
  assign sw[16] = {st_snr_min, st_snr_avg};
  assign sw[17] = {st_noise, st_bad};
  assign sw[18] = {4'd0, st_ldpc_isum, 3'd0, st_ldpc_imax, st_ldpc_fail};
  assign sw[19] = {st_cwfail_count, st_cw_count};
  genvar gi;
  assign sw[20] = {st_w0_adj, 4'd0, st_tau_q8};          // fine timing: window correction [samples], tau (1/256 sample)
  generate for (gi = 21; gi < 31; gi = gi + 1) begin : g_rsv assign sw[gi] = 32'd0; end endgenerate
  assign sw[31] = {13'd0, st_hdr_conf, st_hdr_mism, st_hdr_ok, st_mode, MMSE, CODED} ;
  generate for (gi = 0; gi < NST; gi = gi + 1) begin : g_stat assign stat[32*gi +: 32] = sw[gi]; end endgenerate

  phy_regs_axil #(
    .ID(32'h4F465258), .NCFG(NCFG), .NST(NST),
    .CFG_INIT({{24'd0, TAU_TGT}, {30'd0, SMOOTH, FT_EN}, {19'd0, BAD_THR}, {27'd0, MAX_ITER}, {27'd0, CA, UA, MODE, HDR_EN, MMSE}, {28'd0, GAIN_SH}, RMIN, {24'd0, NSYMS}})
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
