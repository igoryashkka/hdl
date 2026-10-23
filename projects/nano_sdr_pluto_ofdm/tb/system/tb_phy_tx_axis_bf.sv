// System TB (TestTask006): two beamforming boards = two phy_tx_axis_top BF=1, A1 leader (122.88 MHz) and A2 follower (+37 ppm,
// other clock and strobe phase), wired by the JP5 nets (EPOCH, SCLK, MOSI, UP with pull-ups), DAC strobe every 4th clock.
// Sequence: config -> A1 set epoch 100 + force tick -> bus SET_EPOCH(101) to A2 -> A1 commit (own parameters) and bus PARAMS (A2's)
// with target epoch 103 -> at epoch 103 both boards get a TIMED packet (launch index 2000, both channels) -> A1 gets a TIMED SOUND
// packet (channel 1 only, launch 500) that has to wait for a later epoch because the first packet is still playing.
// Self-checks here: epoch numbers equal, apply on both boards at epoch 103, A2's active parameters = the PARAMS frame, bus counters,
// launch counters, launch strobe index (go at index 2000 / 500), first output strobe index identical on both boards.
// Bit-exact check of all four DAC streams (weights incl. tau tracking + tick-phase delay, NCO) is done by python/check_bf_axis.py
// on the dumps written here (sim/work/bf_dump_a1.txt, bf_dump_a2.txt); run_regression.sh runs both.
module bf_board #(parameter real HALF = 4.069, parameter real OFS = 0.0, parameter int SPH = 1, parameter string NAME = "a1") (
  inout wire ep, inout wire sclk, inout wire mosi, inout wire up
);
  logic clk = 0, aclk = 0, rst = 1, aresetn = 0;
  initial begin #(OFS); forever #(HALF) clk = ~clk; end
  always #6.5 aclk = ~aclk;
  logic [1:0] ph = 0;
  always @(posedge clk) ph <= ph + 1'b1;
  wire dac_valid = (ph == 2'(SPH)) && !rst;

  logic s_axis_valid = 0, s_axis_ready, s_axis_last = 0; logic [63:0] s_axis_data = 0;
  logic dac_dunf; logic [15:0] dac_data_i, dac_data_q, dac_data_i1, dac_data_q1;
  logic [11:0] awaddr = 0, araddr = 0; logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
  logic [31:0] wdata = 0; logic [3:0] wstrb = 4'hF;
  logic awready, wready, bvalid, arready, rvalid; logic [1:0] bresp, rresp; logic [31:0] rdata;
  logic ep_o, ep_t, sclk_o, sclk_t, mosi_o, mosi_t, up_o, up_t;
  assign ep = ep_t ? 1'bz : ep_o;
  assign sclk = sclk_t ? 1'bz : sclk_o;
  assign mosi = mosi_t ? 1'bz : mosi_o;
  assign up = up_t ? 1'bz : up_o;
  phy_tx_axis_top #(.GAP(32'd0), .MODE(1'b0), .BF(1'b1)) dut (.clk, .rst, .s_axis_valid, .s_axis_ready, .s_axis_data, .s_axis_last, .dac_valid,
    .dac_data_i, .dac_data_q, .dac_dunf, .dac_data_i1, .dac_data_q1,
    .ep_i(ep), .ep_o, .ep_t, .sclk_i(sclk), .sclk_o, .sclk_t, .mosi_i(mosi), .mosi_o, .mosi_t, .up_i(up), .up_o, .up_t,
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn), .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

  // ---------------------------------------------------------------- AXI-Lite / DMA
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
  logic [31:0] st [64];
  task automatic read_status;
    logic [31:0] v;
    axi_write(12'h008, 1);
    repeat (40) begin axi_read(12'h008, v); if (v[0]) break; end
    for (int k = 0; k < 64; k++) axi_read(12'h080 + 4 * k, st[k]);
  endtask
  task automatic send_beat(input [63:0] d, input bit last);
    @(posedge clk); #1; s_axis_valid = 1; s_axis_data = d; s_axis_last = last;
    do @(posedge clk); while (!s_axis_ready);
    #1; s_axis_valid = 0; s_axis_last = 0;
  endtask
  task automatic dma_packet(input logic [7:0] pay [], input logic [15:0] flags, input logic [31:0] launch);
    logic [63:0] w; int n; n = pay.size();
    send_beat({32'h4F465458, flags, 16'(n)}, 1'b0);
    if (flags[15] && flags[3]) send_beat({32'd0, launch}, 1'b0);
    for (int b = 0; b < n; b += 8) begin
      for (int k = 0; k < 8; k++) w[8*k +: 8] = (b + k < n) ? pay[b + k] : 8'hEE;
      send_beat(w, (b + 8 >= n));
    end
  endtask

  // ---------------------------------------------------------------- dump: one line per strobe after the first apply
  int fd, k_str = -1, n_tau = 0, n_go = 0, go_str [4], go_ntau [4], go_tp [4], go_lg [4], go_idx [4], first_out = -1, n_apply = 0;
  bit dumping = 0;
  initial begin string f; $sformat(f, "bf_dump_%s.txt", NAME); fd = $fopen(f, "w"); end
  always @(posedge clk) if (!rst) begin
    if (dut.g_bf.apply) begin
      n_apply++;
      if (!dumping) begin dumping = 1; k_str = 0; $fdisplay(fd, "A"); end
      n_tau = 0;
    end else if (dac_valid) begin
      if (dut.go_fire && n_go < 4) begin go_ntau[n_go] = n_tau; end
      n_tau++;
    end
    if (dut.go_fire && n_go < 4) begin
      if (dut.g_bf.apply) go_ntau[n_go] = 0;
      go_str[n_go] = k_str; go_tp[n_go] = dut.g_bf.tick_phase; go_lg[n_go] = dut.g_bf.strobe_log2; go_idx[n_go] = dut.g_bf.idx_now;
      $fdisplay(fd, "G %0d %0d %0d %0d %0d", k_str, go_ntau[n_go], go_tp[n_go], go_lg[n_go], go_idx[n_go]);
      n_go++;
    end
    if (dumping && dac_valid) begin
      $fdisplay(fd, "S %0d %0d %08x %08x %08x %08x", k_str, dut.iq_valid, {dut.iq_re, dut.iq_im}, {dut.iq1_re, dut.iq1_im},
                {dac_data_i, dac_data_q}, {dac_data_i1, dac_data_q1});
      if (dut.iq_valid && first_out < 0) first_out = k_str;
      k_str++;
    end
  end
  function automatic void close(); $fclose(fd); endfunction
endmodule

module tb_phy_tx_axis_bf;
  wire ep, sclk, mosi, up;
  pullup (ep); pullup (sclk); pullup (mosi); pullup (up);
  bf_board #(.HALF(4.069),   .OFS(0.0), .SPH(1), .NAME("a1")) a1 (.ep, .sclk, .mosi, .up);
  bf_board #(.HALF(4.06915), .OFS(2.3), .SPH(3), .NAME("a2")) a2 (.ep, .sclk, .mosi, .up);

  logic [7:0]  pay [270];
  logic [31:0] a1par [8];
  logic [7:0]  frm [64];
  int errors = 0;
  localparam int PERIOD = 12000, LAUNCH1 = 2000, LAUNCH2 = 500, TARGET = 103;
  wire [31:0] a1_epoch = a1.dut.g_bf.epoch_num;
  wire        a1_bus_busy = a1.dut.g_bf.tx_busy | a1.dut.g_bf.u_bus.tx_req;

  initial begin #15ms; $display("TEST FAILED tb_phy_tx_axis_bf: TIMEOUT (A1 epoch %0d, bus busy %0d)", a1_epoch, a1_bus_busy); $finish; end
  task automatic step(input string t); $display("step %s at %0t ns (A1 epoch %0d, A2 epoch %0d)", t, $time / 1000, a1_epoch, a2.dut.g_bf.epoch_num); endtask

  task automatic cfg_both;
    // cfg2: ENABLE, MODE 0 (MAX RANGE), mask 01, tick-phase compensation; cfg1 GAP 0; cfg12 period
    a1.axi_write(12'h018, 32'h11); a2.axi_write(12'h018, 32'h11);
    a1.axi_write(12'h040, PERIOD); a2.axi_write(12'h040, PERIOD);
    a1.axi_write(12'h01C, {2'd0, 6'd0, 8'd12, 8'd0, 6'd0, 2'd1}); a2.axi_write(12'h01C, {2'd0, 6'd0, 8'd12, 8'd0, 6'd0, 2'd2});
  endtask
  task automatic bus_send(input int off, input int n);
    for (int w = 0; w < 12; w++) begin
      logic [31:0] v; v = 0;
      for (int b = 0; b < 4; b++) if (4 * w + b < n) v[8*b +: 8] = frm[off + 4 * w + b];
      a1.axi_write(12'h400 + 4 * w, v);
    end
    a1.axi_write(12'h01C, {2'd0, 6'(n), 8'd12, 8'd0, 6'd0, 2'd1});
    a1.axi_write(12'h004, 32'h08);                                      // pulse: bus send
    repeat (50) @(posedge a1.clk);                                    // the pulse crosses to l_clk
    wait (!a1_bus_busy);
    repeat (20) @(posedge a1.clk);
  endtask

  initial begin
    logic [7:0] p2 [];
    int nset, npar;
    $readmemh("vec/tbbf_pkt.mem", pay); $readmemh("vec/tbbf_a1par.mem", a1par); $readmemh("vec/tbbf_frames.mem", frm);
    nset = frm[0]; npar = frm[1 + nset];
    repeat (10) @(posedge a1.clk); a1.rst = 0; a2.rst = 0; a1.aresetn = 1; a2.aresetn = 1;
    repeat (10) @(posedge a1.aclk);
    cfg_both();
    // epoch numbers: A1 100 at a forced tick; A2 gets SET_EPOCH(101) over the bus
    a1.axi_write(12'h048, 100); a1.axi_write(12'h004, 32'h10); a1.axi_write(12'h004, 32'h20);
    wait (a1_epoch == 100); @(posedge a1.clk); step("epoch 100");
    bus_send(1, nset); step("SET_EPOCH sent");
    wait (a1_epoch == 101); @(posedge a1.clk); repeat (100) @(posedge a1.clk);
    if (a2.dut.g_bf.epoch_num !== 32'd101) begin errors++; $display("A2 epoch %0d != 101", a2.dut.g_bf.epoch_num); end
    // parameters for epoch 103: A1 own (commit), A2 over the bus
    for (int i = 0; i < 8; i++) a1.axi_write(12'h020 + 4 * i, a1par[i]);
    a1.axi_write(12'h044, TARGET); a1.axi_write(12'h004, 32'h04);
    bus_send(2 + nset, npar); step("PARAMS sent");
    wait (a1_epoch == TARGET); @(posedge a1.clk); repeat (8) @(posedge a1.clk); step("target epoch");
    if (a1.n_apply != 1 || a2.n_apply != 1) begin errors++; $display("applies %0d %0d", a1.n_apply, a2.n_apply); end
    // A2 active = PARAMS frame channel blocks (bytes 5+4 .. 5+4+31 of the frame)
    begin
      logic [255:0] e;
      for (int b = 0; b < 32; b++) e[8*b +: 8] = frm[1 + nset + 1 + 9 + b];
      if (a2.dut.g_bf.active !== e) begin errors++; $display("A2 active %h != %h", a2.dut.g_bf.active, e); end
      for (int i = 0; i < 8; i++) if (a1.dut.g_bf.active[32*i +: 32] !== a1par[i]) begin errors++; $display("A1 active word %0d", i); end
    end
    // timed packets on both boards (both channels), then a timed SOUND packet on A1 (channel 1)
    p2 = new[270]; foreach (pay[i]) p2[i] = pay[i];
    fork
      a1.dma_packet(p2, 16'h800B, LAUNCH1);
      a2.dma_packet(p2, 16'h800B, LAUNCH1);
    join
    a1.dma_packet(p2, 16'h800E, LAUNCH2);
    repeat (5 * PERIOD * 4) @(posedge a1.clk);
    a1.read_status(); a2.read_status();
    a1.close(); a2.close();
    if (a1.st[22] !== 2 || a2.st[22] !== 1) begin errors++; $display("timed launches %0d %0d", a1.st[22], a2.st[22]); end
    if (a1.go_idx[0] != LAUNCH1 || a2.go_idx[0] != LAUNCH1 || a1.go_idx[1] != LAUNCH2) begin errors++; $display("go index %0d %0d %0d", a1.go_idx[0], a2.go_idx[0], a1.go_idx[1]); end
    if (a1.st[16] !== a2.st[16]) begin errors++; $display("epoch numbers %0d %0d", a1.st[16], a2.st[16]); end
    if (a2.st[24][15:0] !== 2 || a2.st[24][31:16] !== 0 || a1.st[25][15:0] !== 2 || a1.st[25][31:16] !== 0) begin errors++; $display("bus counters %08x %08x", a2.st[24], a1.st[25]); end
    if (a1.st[31][2] !== 1'b1) begin errors++; $display("BF flag in status 31"); end
    if (a1.first_out - a1.go_str[0] != a2.first_out - a2.go_str[0]) begin errors++; $display("launch latency differs %0d %0d", a1.first_out - a1.go_str[0], a2.first_out - a2.go_str[0]); end
    $display("launch -> first sample latency %0d strobes; tick_phase A1 %0d A2 %0d; tau strobes A1 %0d A2 %0d", a1.first_out - a1.go_str[0],
             a1.go_tp[0], a2.go_tp[0], a1.go_ntau[0], a2.go_ntau[0]);
    if (errors == 0) $display("TEST PASSED tb_phy_tx_axis_bf (control part; DAC streams: python/check_bf_axis.py)");
    else $display("TEST FAILED tb_phy_tx_axis_bf errors=%0d", errors);
    $finish;
  end
endmodule

