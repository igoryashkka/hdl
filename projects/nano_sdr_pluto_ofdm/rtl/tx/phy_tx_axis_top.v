// ***************************************************************************
// phy_tx_axis_top -- TX-only build wrapper: packets from the PS (axi_dmac, memory -> AXI-stream, 64-bit)
//   -> phy_tx_top (OFDM PHY) -> IQ to the AD9361 DAC interface (l_clk domain, pulled by dac_valid),
//   plus an AXI4-Lite register block (control + logging).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Stream format (one DMA transfer per packet, tlast on the last beat; beats are 64 bit, bytes LSB first):
//   beat 0 : {32'h4F465458 ('OFTX'), 16'h0000, nbytes[15:0]}   (header, consumed here)
//   beat 1..: payload, nbytes bytes (the remainder of the last beat is ignored); the PHY zero-pads it to a multiple of 550
//             bytes (one OFDM symbol). Packets with a bad header are dropped (counted).
// Inter-packet gap: the next packet is accepted only when the PHY is idle and `gap_samples` DAC samples have elapsed since
//   it became idle (the receiver handles one packet at a time and needs ~12000 samples to re-arm).
// Registers (base 0x7C440000 in the BD, generic part in rtl/common/phy_regs_axil.v):
//   cfg 0x10 GAIN (Q2.14, 16384 = 1.0)   0x14 GAP_SAMPLES   0x18 ENABLE (bit0, packets are only accepted when 1) + MODE (bit1: 0 = MAX RANGE
//   QPSK + LDPC 1/2, 1 = MAX RATE 16-QAM + LDPC 5/6; sampled with the first byte of a packet, change it only between packets)
//   status snapshot words (write SNAP 0x08, poll bit0, read 0x80 + 4*i):
//     0 {pkt_done, pkt_accepted}   1 {trunc, overflow}   2 {bad_header, underflow}   3 dac samples   4 clk count
//     5 busy clocks   6 active (non-idle) dac samples   7 {peak|q|, peak|i|} of the output   8 dma beats   9 dma stall clocks
//     10 last nbytes   11 {.., state, busy}   12 gap counter   13 gain   14 last iq {q, i}   15 bad-header dropped beats
// ***************************************************************************
`timescale 1ns/100ps

module phy_tx_axis_top #(
  parameter [15:0] GAIN    = 16'd16384,
  parameter [31:0] GAP     = 32'd16384,
  parameter        ENABLE  = 1'b1,
  parameter        MODE    = 1'b1,            // reset value of the PHY mode (1 = MAX RATE, 0 = MAX RANGE)
  parameter        CODED   = 1'b1             // LDPC R=5/6 (450 payload bytes per OFDM symbol, Zynq-7020 design); 0 = uncoded (550)
) (
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF PHY_STREAM" *)   /* keeps l_clk away from the AXI-Lite port (ad_cpu_interconnect picks the S_AXI clock by ASSOCIATED_BUSIF) */
  input         clk,           // AD9361 l_clk
  (* X_INTERFACE_INFO = "xilinx.com:signal:data:1.0 rst DATA" *)    /* plain signal: keeps Vivado from auto-associating it with s_axi_aclk */
  input         rst,
  input         s_axis_valid,
  output        s_axis_ready,
  input  [63:0] s_axis_data,
  input         s_axis_last,
  input         dac_valid,     // core requests one sample
  output [15:0] dac_data_i,
  output [15:0] dac_data_q,
  output        dac_dunf,

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
  localparam NST  = 32;
  localparam [31:0] MAGIC = 32'h4F465458;
  localparam [1:0] S_HDR = 2'd0, S_BODY = 2'd1, S_DRAIN = 2'd2;

  wire [32*NCFG-1:0] cfg;
  wire               soft_rst, clr;
  wire [32*NST-1:0]  stat;
  wire [15:0]        gain_w   = cfg[15:0];
  wire [31:0]        gap_w    = cfg[63:32];
  wire               enable_w = cfg[64];
  wire               mode_w   = cfg[65];

  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout) + PS soft reset
  always @(posedge clk) rst_r <= rst | soft_rst;

  // ---------------------------------------------------------------- packet framing + 64 -> 8 bit serialiser
  reg [1:0]  st = S_HDR;
  reg [63:0] word = 64'd0;
  reg        got_last = 1'b0;
  reg [3:0]  left = 4'd0;                // bytes left in `word`
  reg [15:0] rem = 16'd0;                // payload bytes still to be sent
  reg [31:0] gap_cnt = 32'd0;
  wire       phy_ready, phy_busy;
  wire       gap_ok = (gap_cnt >= gap_w);

  reg [15:0] n_acc = 0, n_bad = 0, n_unf = 0, n_ovf = 0, n_trunc = 0, n_done = 0, last_nb = 0;
  reg [31:0] n_beat = 0, n_stall = 0, n_samp = 0, n_clk = 0, n_busy = 0, n_act = 0, n_dropped = 0;
  reg [15:0] pk_i = 0, pk_q = 0;
  reg [31:0] last_iq = 0;

  wire in_hdr   = (st == S_HDR);
  assign s_axis_ready = (in_hdr && gap_ok && enable_w && !phy_busy) || (st == S_BODY && left == 4'd0 && rem != 16'd0) || (st == S_DRAIN);
  wire acc = s_axis_valid && s_axis_ready;

  wire byte_valid = (st == S_BODY) && (left != 4'd0) && (rem != 16'd0);
  wire byte_take  = byte_valid && phy_ready;
  wire last_byte  = (rem == 16'd1) || (got_last && left == 4'd1);

  wire hdr_ok = (s_axis_data[63:32] == MAGIC) && (s_axis_data[15:0] != 16'd0) && !s_axis_last;

  always @(posedge clk) begin
    if (rst_r) begin
      st <= S_HDR; left <= 4'd0; word <= 64'd0; got_last <= 1'b0; rem <= 16'd0;
    end else begin
      if (acc) begin
        case (st)
          S_HDR: begin
            if (hdr_ok) begin st <= S_BODY; rem <= s_axis_data[15:0]; left <= 4'd0; got_last <= 1'b0; end
            else if (!s_axis_last) st <= S_DRAIN;
          end
          S_BODY: begin word <= s_axis_data; left <= 4'd8; got_last <= s_axis_last; end
          S_DRAIN: if (s_axis_last) st <= S_HDR;
          default: st <= S_HDR;
        endcase
      end else if (byte_take) begin
        word <= {8'd0, word[63:8]};
        left <= left - 4'd1;
        rem  <= rem - 16'd1;
        if (last_byte) begin left <= 4'd0; rem <= 16'd0; st <= got_last ? S_HDR : S_DRAIN; end
      end
    end
  end

  wire        pkt_done;
  wire [15:0] iq_re, iq_im;
  wire        iq_valid, underflow, overflow, trunc;

  phy_tx_top #(.CODED(CODED)) u_phy (
    .clk(clk), .rst(rst_r), .gain(gain_w), .cfg_mode(mode_w),
    .s_valid(byte_valid), .s_ready(phy_ready), .s_data(word[7:0]), .s_last(last_byte),
    .iq_pull(dac_valid), .iq_re(iq_re), .iq_im(iq_im), .iq_valid(iq_valid),
    .underflow(underflow), .overflow(overflow), .pkt_trunc(trunc), .pkt_done(pkt_done),
    .busy(phy_busy)
  );

  assign dac_data_i = iq_re;
  assign dac_data_q = iq_im;
  assign dac_dunf   = underflow;

  // ---------------------------------------------------------------- gap counter + logging counters (cleared by `clr`)
  // the output samples come straight from a BRAM: register them before the logging logic (timing)
  reg [15:0] re_q = 0, im_q = 0; reg act_q = 1'b0;
  always @(posedge clk) begin re_q <= iq_re; im_q <= iq_im; act_q <= dac_valid && iq_valid; end
  wire [15:0] ai = re_q[15] ? (~re_q + 16'd1) : re_q;
  wire [15:0] aq = im_q[15] ? (~im_q + 16'd1) : im_q;
  wire        hdr_beat = acc && in_hdr;
  always @(posedge clk) begin
    if (rst_r) gap_cnt <= 32'd0;
    else if (phy_busy || (st != S_HDR)) gap_cnt <= 32'd0;
    else if (dac_valid && !gap_ok) gap_cnt <= gap_cnt + 32'd1;

    if (rst_r || clr) begin
      n_acc <= 0; n_bad <= 0; n_unf <= 0; n_ovf <= 0; n_trunc <= 0; n_done <= 0; n_beat <= 0; n_stall <= 0;
      n_samp <= 0; n_clk <= 0; n_busy <= 0; n_act <= 0; n_dropped <= 0; pk_i <= 0; pk_q <= 0;
    end else begin
      n_clk <= n_clk + 1'b1;
      if (phy_busy) n_busy <= n_busy + 1'b1;
      if (dac_valid) n_samp <= n_samp + 1'b1;
      if (act_q) begin
        n_act <= n_act + 1'b1;
        if (ai > pk_i) pk_i <= ai;
        if (aq > pk_q) pk_q <= aq;
        last_iq <= {im_q, re_q};
      end
      if (acc) n_beat <= n_beat + 1'b1;
      if (s_axis_valid && !s_axis_ready) n_stall <= n_stall + 1'b1;
      if (hdr_beat && hdr_ok) begin n_acc <= n_acc + 1'b1; last_nb <= s_axis_data[15:0]; end
      if (hdr_beat && !hdr_ok) n_bad <= n_bad + 1'b1;
      if (acc && st == S_DRAIN) n_dropped <= n_dropped + 1'b1;
      if (underflow) n_unf <= n_unf + 1'b1;
      if (overflow) n_ovf <= n_ovf + 1'b1;
      if (trunc) n_trunc <= n_trunc + 1'b1;
      if (pkt_done) n_done <= n_done + 1'b1;
    end
  end

  wire [31:0] sw [0:NST-1];
  assign sw[0]  = {n_done, n_acc};
  assign sw[1]  = {n_trunc, n_ovf};
  assign sw[2]  = {n_bad, n_unf};
  assign sw[3]  = n_samp;
  assign sw[4]  = n_clk;
  assign sw[5]  = n_busy;
  assign sw[6]  = n_act;
  assign sw[7]  = {pk_q, pk_i};
  assign sw[8]  = n_beat;
  assign sw[9]  = n_stall;
  assign sw[10] = {16'd0, last_nb};
  assign sw[11] = {28'd0, st, 1'b0, phy_busy};
  assign sw[12] = gap_cnt;
  assign sw[13] = {16'd0, gain_w};
  assign sw[14] = last_iq;
  assign sw[15] = n_dropped;
  genvar gi;
  generate for (gi = 16; gi < 31; gi = gi + 1) begin : g_rsv assign sw[gi] = 32'd0; end endgenerate
  assign sw[31] = {30'd0, mode_w, CODED};
  generate for (gi = 0; gi < NST; gi = gi + 1) begin : g_stat assign stat[32*gi +: 32] = sw[gi]; end endgenerate

  phy_regs_axil #(
    .ID(32'h4F465458), .NCFG(NCFG), .NST(NST),
    .CFG_INIT({{30'd0, MODE, ENABLE}, GAP, 16'd0, GAIN})
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
