// System TB: phy_rx_axis_top (RX wrapper + AXI-Lite logging registers) on the same two-packet ADC stream as tb_phy_rx_top.
// The PS bus runs on an unrelated clock (100 MHz) next to the AD9361 clock (assumed here 8 ns). Checks through AXI reads:
//   ID, config reset values + write/readback, snapshot (SNAP) handshake, det/pkt counters == 2, sample counter == stream length,
//   DMA beat counter == 2 packets, ADC peak > 0, rssi code / evm / cfo_inc / n_best of the last packet vs the Python values,
//   statistics clear (counters restart), soft reset (counters of the PHY restart).
module tb_phy_rx_axis_top;
  localparam int NS = 30745, NPKT = 2, NSYMS = 2, PBYTES = NSYMS * 550, NBEATS = 3 + (PBYTES + 7) / 8;
  logic clk = 0, aclk = 0, rst = 1, aresetn = 0;
  always #4 clk = ~clk;
  always #5 aclk = ~aclk;
  logic [31:0] samples [NS];
  logic [31:0] ev [NPKT * 4];
  logic in_valid = 0; logic signed [15:0] i_in = 0, q_in = 0;
  logic m_axis_valid, m_axis_ready = 1, m_axis_last; logic [63:0] m_axis_data;
  logic [11:0] awaddr = 0, araddr = 0; logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
  logic [31:0] wdata = 0; logic [3:0] wstrb = 4'hF;
  logic awready, wready, bvalid, arready, rvalid; logic [1:0] bresp, rresp; logic [31:0] rdata;
  phy_rx_axis_top dut (.clk, .rst, .in_valid, .i_in, .q_in, .m_axis_valid, .m_axis_ready, .m_axis_data, .m_axis_last,
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn), .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

  int errors = 0;
  logic [63:0] hdr2 [NPKT]; int npkt = 0, nbeat = 0;
  always @(posedge clk) if (!rst && m_axis_valid && m_axis_ready) begin
    if (nbeat == 2 && npkt < NPKT) hdr2[npkt] = m_axis_data;
    nbeat++;
    if (m_axis_last) begin npkt++; nbeat = 0; end
  end

  task automatic axi_write(input [11:0] a, input [31:0] d);
    @(posedge aclk); #1; awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
    do @(posedge aclk); while (!(awready && wready));
    #1; awvalid = 0; wvalid = 0; repeat (2) @(posedge aclk); #1;
  endtask
  task automatic axi_read(input [11:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1;
    do @(posedge aclk); while (!arready);
    d = rdata; #1; arvalid = 0; repeat (2) @(posedge aclk); #1;
  endtask
  task automatic snap;
    logic [31:0] v;
    axi_write(12'h008, 1);
    repeat (40) begin axi_read(12'h008, v); if (v[0]) break; end
    if (!v[0]) begin errors++; $display("snapshot timeout"); end
  endtask

  logic [31:0] v;
  logic [31:0] w [16];
  task automatic read_status;
    snap();
    for (int k = 0; k < 16; k++) axi_read(12'h080 + 4 * k, w[k]);
  endtask

  initial begin
    $readmemh("vec/rxs_in.mem", samples);
    $readmemh("vec/rxs_ev.mem", ev);
    repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge aclk); aresetn = 1; repeat (4) @(posedge clk);
    axi_read(12'h000, v); if (v !== 32'h4F465258) begin errors++; $display("ID %08x", v); end
    axi_read(12'h010, v); if (v[7:0] !== NSYMS) begin errors++; $display("cfg nsyms %0d", v); end
    axi_read(12'h014, v); if (v !== 32'd262144) begin errors++; $display("cfg rmin %0d", v); end
    axi_write(12'h004, 2);           // clear stats at start
    for (int n = 0; n < NS; n++) begin
      @(posedge clk); #1; in_valid = 1; i_in = samples[n][31:16]; q_in = samples[n][15:0];
      @(posedge clk); #1; in_valid = 0;
    end
    repeat (30000) @(posedge clk);
    read_status();
    if (w[0][15:0] !== 2 || w[0][31:16] !== 2) begin errors++; $display("det/pkt %0d/%0d", w[0][15:0], w[0][31:16]); end
    if (w[1] !== 0) begin errors++; $display("drop/wd %08x", w[1]); end
    if (w[2][7:0] !== 0 || w[2][8] !== 0) begin errors++; $display("flags/busy %03x", w[2][8:0]); end
    if (w[3] !== NS) begin errors++; $display("sample count %0d != %0d", w[3], NS); end
    if (w[4] < 2 * NS) begin errors++; $display("clock count %0d", w[4]); end
    if (w[5][15:0] == 0 || w[5][31:16] == 0) begin errors++; $display("ADC peak %08x", w[5]); end
    if (w[7][15:0] !== ev[4 * (NPKT - 1) + 2][15:0]) begin errors++; $display("rssi %04x exp %04x", w[7][15:0], ev[4 * (NPKT - 1) + 2][15:0]); end
    if (w[9] !== ev[4 * (NPKT - 1) + 1]) begin errors++; $display("cfo_inc %08x exp %08x", w[9], ev[4 * (NPKT - 1) + 1]); end
    if (w[10] !== ev[4 * (NPKT - 1)]) begin errors++; $display("n_best %0d exp %0d", w[10], ev[4 * (NPKT - 1)]); end
    if (w[11][15:0] !== NPKT - 1) begin errors++; $display("seq register %0d (exp %0d: count at commit)", w[11][15:0], NPKT - 1); end
    if (w[8] !== hdr2[NPKT - 1][31:0] || w[7] !== {hdr2[NPKT - 1][63:48], hdr2[NPKT - 1][47:32]}) begin errors++; $display("regs vs header beat: evm %08x/%08x", w[8], hdr2[NPKT - 1][31:0]); end
    if (w[12] !== NPKT * NBEATS) begin errors++; $display("beats %0d != %0d", w[12], NPKT * NBEATS); end
    // clear: counters restart, PHY counters keep running
    axi_write(12'h004, 2); read_status();
    if (w[3] > 100 || w[12] !== 0 || w[5] !== 0) begin errors++; $display("clear failed: samp %0d beats %0d peak %08x", w[3], w[12], w[5]); end
    if (w[0][15:0] !== 2) begin errors++; $display("det count lost by clear"); end
    // soft reset restarts the PHY counters
    axi_write(12'h004, 1); repeat (20) @(posedge clk); axi_write(12'h004, 0); repeat (20) @(posedge clk);
    read_status();
    if (w[0] !== 0) begin errors++; $display("soft reset did not clear PHY counters %08x", w[0]); end
    // config write passes through
    axi_write(12'h010, 32'd1); axi_read(12'h010, v); if (v[7:0] !== 1) begin errors++; $display("nsyms readback"); end
    if (errors == 0) $display("TEST PASSED tb_phy_rx_axis_top (%0d packets, regs verified)", NPKT);
    else $display("TEST FAILED tb_phy_rx_axis_top errors=%0d", errors);
    $finish;
  end
endmodule
