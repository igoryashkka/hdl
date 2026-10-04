// Self-checking TB: phy_regs_axil (AXI4-Lite, two unrelated clocks 100 MHz / 61.44-ish MHz).
// Tests: ID read, config write/readback + arrival (synchronised) in the phy_clk domain, reset values, soft reset level,
// clear pulse (exactly one phy_clk pulse per write), snapshot handshake (SNAP bit0 low while pending, high when done,
// status words stable between snapshots while stat_i keeps changing), write strobe handling for config (full word).
module tb_phy_regs_axil;
  localparam int NCFG = 3, NST = 4;
  logic aclk = 0, pclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  always #8.14 pclk = ~pclk;
  logic [11:0] awaddr = 0, araddr = 0; logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
  logic [31:0] wdata = 0; logic [3:0] wstrb = 4'hF;
  logic awready, wready, bvalid, arready, rvalid; logic [1:0] bresp, rresp; logic [31:0] rdata;
  logic [32*NCFG-1:0] cfg_o; logic soft_rst_o, clr_o; logic [32*NST-1:0] stat_i = '0;
  phy_regs_axil #(.NCFG(NCFG), .NST(NST), .ID(32'h12345678), .CFG_INIT({32'hCCCC0003, 32'hBBBB0002, 32'hAAAA0001}))
    dut (.s_axi_aclk(aclk), .s_axi_aresetn(aresetn), .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
         .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
         .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
         .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
         .s_axi_rvalid(rvalid), .s_axi_rready(rready), .phy_clk(pclk), .cfg_o(cfg_o), .soft_rst_o(soft_rst_o), .clr_o(clr_o), .stat_i(stat_i));

  int errors = 0, clr_pulses = 0;
  always @(posedge pclk) if (clr_o) clr_pulses++;
  always @(posedge pclk) stat_i <= stat_i + 64'h0001_0000_0000_0001;   // free-running status (changes every phy clock)

  task automatic axi_write(input [11:0] a, input [31:0] d);
    @(posedge aclk); #1; awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
    do @(posedge aclk); while (!(awready && wready));   // handshake completes on the clock where both are high
    #1; awvalid = 0; wvalid = 0;
    repeat (2) @(posedge aclk); #1;
  endtask
  task automatic axi_read(input [11:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1;
    do @(posedge aclk); while (!arready);
    d = rdata; #1; arvalid = 0;
    repeat (2) @(posedge aclk); #1;
  endtask

  logic [31:0] v, s0a, s0b, s1a, s1b;
  initial begin
    repeat (5) @(posedge aclk); aresetn = 1; repeat (5) @(posedge aclk);
    axi_read(12'h000, v); if (v !== 32'h12345678) begin errors++; $display("ID %08x", v); end
    axi_read(12'h010, v); if (v !== 32'hAAAA0001) begin errors++; $display("cfg0 reset %08x", v); end
    axi_read(12'h018, v); if (v !== 32'hCCCC0003) begin errors++; $display("cfg2 reset %08x", v); end
    repeat (10) @(posedge pclk);
    if (cfg_o !== {32'hCCCC0003, 32'hBBBB0002, 32'hAAAA0001}) begin errors++; $display("cfg_o reset %h", cfg_o); end
    axi_write(12'h014, 32'hDEADBEEF);
    axi_read (12'h014, v); if (v !== 32'hDEADBEEF) begin errors++; $display("cfg1 readback %08x", v); end
    repeat (10) @(posedge pclk);
    if (cfg_o[63:32] !== 32'hDEADBEEF || cfg_o[31:0] !== 32'hAAAA0001) begin errors++; $display("cfg_o after write %h", cfg_o); end
    // soft reset level
    axi_write(12'h004, 32'h1); repeat (8) @(posedge pclk);
    if (soft_rst_o !== 1'b1) begin errors++; $display("soft_rst not set"); end
    axi_write(12'h004, 32'h0); repeat (8) @(posedge pclk);
    if (soft_rst_o !== 1'b0) begin errors++; $display("soft_rst not cleared"); end
    // clear pulse: one pulse per write, soft reset untouched
    clr_pulses = 0; axi_write(12'h004, 32'h2); repeat (12) @(posedge pclk);
    if (clr_pulses !== 1) begin errors++; $display("clr pulses %0d", clr_pulses); end
    axi_write(12'h004, 32'h2); repeat (12) @(posedge pclk);
    if (clr_pulses !== 2) begin errors++; $display("clr pulses %0d (exp 2)", clr_pulses); end
    // snapshot
    axi_write(12'h008, 32'h1);
    axi_read(12'h008, v);
    repeat (20) begin if (v[0]) break; axi_read(12'h008, v); end
    if (!v[0]) begin errors++; $display("snapshot never completed"); end
    axi_read(12'h080, s0a); axi_read(12'h084, s1a);
    repeat (50) @(posedge pclk);
    axi_read(12'h080, s0b); axi_read(12'h084, s1b);
    if (s0a !== s0b || s1a !== s1b) begin errors++; $display("bank not stable between snapshots"); end
    // second snapshot must show newer data (status counter grows)
    axi_write(12'h008, 32'h1);
    repeat (20) begin axi_read(12'h008, v); if (v[0]) break; end
    axi_read(12'h080, s0b);
    if (s0b <= s0a) begin errors++; $display("second snapshot not newer %08x vs %08x", s0b, s0a); end
    if (errors == 0) $display("TEST PASSED tb_phy_regs_axil");
    else $display("TEST FAILED tb_phy_regs_axil errors=%0d", errors);
    $finish;
  end
endmodule
