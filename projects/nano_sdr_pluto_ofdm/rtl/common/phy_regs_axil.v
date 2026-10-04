// ***************************************************************************
// phy_regs_axil -- AXI4-Lite control/status block for the OFDM PHY wrappers (two clock domains).
//   s_axi_aclk domain : PS bus (FCLK0).      phy_clk domain : AD9361 l_clk (the PHY).
// Register map (byte offsets):
//   0x00 ID        RO   module id (parameter ID)
//   0x04 CTRL      RW   [0] soft reset of the PHY (level)   [1] clear statistics (write 1, self-clearing pulse)
//   0x08 SNAP      RW   write any value -> latch all status words into the shadow bank (phy_clk domain);
//                       read bit0 = 1 when the snapshot is complete (poll before reading 0x80..)
//   0x10 + 4*i     RW   configuration words i = 0..NCFG-1 (reset value CFG_INIT[32*i +: 32]), passed to phy_clk through 2-FF
//                       synchronisers (quasi-static: change them while the PHY is idle / in soft reset)
//   0x80 + 4*i     RO   status snapshot words i = 0..NST-1 (taken from stat_i on SNAP; stable between snapshots)
// CDC: cfg / soft reset = 2-FF synchronisers; clear = toggle + 2-FF + edge; snapshot = request toggle -> phy_clk copy ->
// acknowledge toggle -> s_axi_aclk (handshake, the bank is only written while no read is expected: C code polls SNAP first).
// The synchroniser flops and the status bank are named *_s1 / stat_bank so that the XDC can false-path them.
// ***************************************************************************
`timescale 1ns/100ps

module phy_regs_axil #(
  parameter [31:0] ID       = 32'h4F465800,
  parameter        NCFG     = 4,
  parameter        NST      = 16,
  parameter [32*NCFG-1:0] CFG_INIT = {32*NCFG{1'b0}}
) (
  input             s_axi_aclk,
  input             s_axi_aresetn,
  input      [11:0] s_axi_awaddr,
  input             s_axi_awvalid,
  output reg        s_axi_awready,
  input      [31:0] s_axi_wdata,
  input      [3:0]  s_axi_wstrb,
  input             s_axi_wvalid,
  output reg        s_axi_wready,
  output reg [1:0]  s_axi_bresp,
  output reg        s_axi_bvalid,
  input             s_axi_bready,
  input      [11:0] s_axi_araddr,
  input             s_axi_arvalid,
  output reg        s_axi_arready,
  output reg [31:0] s_axi_rdata,
  output reg [1:0]  s_axi_rresp,
  output reg        s_axi_rvalid,
  input             s_axi_rready,

  input                 phy_clk,
  output [32*NCFG-1:0]  cfg_o,       // phy_clk domain
  output                soft_rst_o,  // phy_clk domain, level
  output reg            clr_o,       // phy_clk domain, 1 clock pulse
  input  [32*NST-1:0]   stat_i       // phy_clk domain, any (sampled on snapshot)
);
  // ------------------------------------------------------------------ AXI domain registers
  reg [31:0]        cfg_r [0:NCFG-1];
  reg               soft_rst_r;
  reg               clr_tog;
  reg               snap_req_tog;
  integer           i;

  // acknowledge from phy_clk (synchronised below)
  (* ASYNC_REG = "TRUE" *) reg ack_s1, ack_s2;
  wire              snap_ack_sync;
  wire              snap_pending = (snap_req_tog != snap_ack_sync);

  wire wr_fire = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
  wire [11:0] wa = s_axi_awaddr;
  wire        w_cfg = (wa >= 12'h010) && (wa < 12'h010 + 4 * NCFG);
  wire [11:0] w_cfg_idx = (wa - 12'h010) >> 2;

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
      soft_rst_r <= 1'b0; clr_tog <= 1'b0; snap_req_tog <= 1'b0;
      for (i = 0; i < NCFG; i = i + 1) cfg_r[i] <= CFG_INIT[32*i +: 32];
    end else begin
      s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
      if (wr_fire) begin
        s_axi_awready <= 1'b1; s_axi_wready <= 1'b1; s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
        if (wa == 12'h004) begin
          soft_rst_r <= s_axi_wdata[0];
          if (s_axi_wdata[1]) clr_tog <= ~clr_tog;
        end else if (wa == 12'h008) begin
          if (!snap_pending) snap_req_tog <= ~snap_req_tog;
        end else if (w_cfg) begin
          cfg_r[w_cfg_idx] <= s_axi_wdata;
        end
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
  end

  // ------------------------------------------------------------------ read channel
  wire [11:0] ra = s_axi_araddr;
  reg  [31:0] rd_mux;
  (* ASYNC_REG = "TRUE" *) reg [32*NST-1:0] stat_bank;       // phy_clk domain shadow bank (read asynchronously)
  always @* begin
    rd_mux = 32'd0;
    if (ra == 12'h000) rd_mux = ID;
    else if (ra == 12'h004) rd_mux = {30'd0, 1'b0, soft_rst_r};
    else if (ra == 12'h008) rd_mux = {31'd0, ~snap_pending};
    else if (ra >= 12'h010 && ra < 12'h010 + 4 * NCFG) rd_mux = cfg_r[(ra - 12'h010) >> 2];
    else if (ra >= 12'h080 && ra < 12'h080 + 4 * NST) rd_mux = stat_bank[32 * ((ra - 12'h080) >> 2) +: 32];
  end

  always @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
    end else begin
      s_axi_arready <= 1'b0;
      if (s_axi_arvalid && !s_axi_rvalid && !s_axi_arready) begin
        s_axi_arready <= 1'b1; s_axi_rvalid <= 1'b1; s_axi_rdata <= rd_mux; s_axi_rresp <= 2'b00;
      end else if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end

  // ------------------------------------------------------------------ AXI -> phy_clk
  (* ASYNC_REG = "TRUE" *) reg [32*NCFG-1:0] cfg_s1, cfg_s2;
  (* ASYNC_REG = "TRUE" *) reg               rst_s1, rst_s2;
  (* ASYNC_REG = "TRUE" *) reg               clr_s1, clr_s2;
  (* ASYNC_REG = "TRUE" *) reg               req_s1, req_s2;
  reg clr_s3, req_s3;
  reg ack_tog;
  reg [32*NCFG-1:0] cfg_flat;
  always @* for (i = 0; i < NCFG; i = i + 1) cfg_flat[32*i +: 32] = cfg_r[i];

  always @(posedge phy_clk) begin
    cfg_s1 <= cfg_flat; cfg_s2 <= cfg_s1;
    rst_s1 <= soft_rst_r; rst_s2 <= rst_s1;
    clr_s1 <= clr_tog; clr_s2 <= clr_s1; clr_s3 <= clr_s2;
    req_s1 <= snap_req_tog; req_s2 <= req_s1; req_s3 <= req_s2;
    clr_o <= (clr_s2 != clr_s3);
    if (req_s2 != req_s3) begin
      stat_bank <= stat_i;
      ack_tog   <= ~ack_tog;
    end
  end
  initial begin
    ack_tog = 1'b0; req_s1 = 1'b0; req_s2 = 1'b0; req_s3 = 1'b0; clr_s1 = 1'b0; clr_s2 = 1'b0; clr_s3 = 1'b0; clr_o = 1'b0;
    rst_s1 = 1'b0; rst_s2 = 1'b0; cfg_s1 = {32*NCFG{1'b0}}; cfg_s2 = {32*NCFG{1'b0}}; stat_bank = {32*NST{1'b0}};
    ack_s1 = 1'b0; ack_s2 = 1'b0;
  end

  assign cfg_o      = cfg_s2;
  assign soft_rst_o = rst_s2;

  // ------------------------------------------------------------------ phy_clk -> AXI (acknowledge)
  always @(posedge s_axi_aclk) begin ack_s1 <= ack_tog; ack_s2 <= ack_s1; end
  assign snap_ack_sync = ack_s2;
endmodule
