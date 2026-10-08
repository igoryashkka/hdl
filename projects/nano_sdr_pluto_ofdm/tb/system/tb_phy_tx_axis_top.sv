// System TB: phy_tx_axis_top (DMA framing + gap + AXI-Lite registers + whole TX chain) vs python/tx_ref.py (bit-exact IQ).
// DMA stream: header beat {OFTX, nbytes} + payload beats with garbage in the unused tail of the last beat (must be ignored),
// a packet with a bad magic (must be dropped and counted), then a second valid packet. Checks: IQ bit-exact for both valid
// packets, minimum gap (cfg GAP) between the end of the first and the start of the second packet, enable=0 blocks the
// stream, registers (counters, config readback, clear). DAC strobe every 2nd clock; PS bus on an unrelated clock.
module tb_phy_tx_axis_top;
  localparam int SYM = 2192, NA = 4 * SYM, NB = 4 * SYM, GAPS = 3000;
  logic clk = 0, aclk = 0, rst = 1, aresetn = 0;
  always #5 clk = ~clk;
  always #6.5 aclk = ~aclk;
  logic [7:0]  pkt0 [900];
  logic [7:0]  pkt1 [500];
  logic [31:0] exp0 [NA];
  logic [31:0] exp1 [NB];
  logic s_axis_valid = 0, s_axis_ready, s_axis_last = 0; logic [63:0] s_axis_data = 0;
  logic dac_valid = 0, dac_dunf; logic signed [15:0] dac_data_i, dac_data_q;
  logic [11:0] awaddr = 0, araddr = 0; logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
  logic [31:0] wdata = 0; logic [3:0] wstrb = 4'hF;
  logic awready, wready, bvalid, arready, rvalid; logic [1:0] bresp, rresp; logic [31:0] rdata;
  phy_tx_axis_top #(.GAP(32'd0)) dut (.clk, .rst, .s_axis_valid, .s_axis_ready, .s_axis_data, .s_axis_last, .dac_valid,
    .dac_data_i, .dac_data_q, .dac_dunf,
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn), .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready));

  int errors = 0, nout = 0, nsamp = 0, last_act0 = -1, first_act1 = -1;
  bit toggle = 0, checking = 0;
  always @(posedge clk) begin toggle <= ~toggle; dac_valid <= toggle & checking; end

  // iq is valid in the same cycle as the pull strobe (iq_pull = dac_valid)
  always @(posedge clk) if (checking && !rst) begin
    if (dac_valid) begin
      nsamp++;
      if (dut.iq_valid) begin
        logic [31:0] e;
        e = (nout < NA) ? exp0[nout] : exp1[nout - NA];
        if ({dac_data_i, dac_data_q} !== e) begin errors++; if (errors < 10) $display("DATA mismatch #%0d got %04x/%04x exp %08x", nout, dac_data_i & 16'hFFFF, dac_data_q & 16'hFFFF, e); end
        if (nout == NA - 1) last_act0 = nsamp;
        if (nout == NA) first_act1 = nsamp;
        nout++;
      end
    end
    if (dac_dunf) begin errors++; if (errors < 5) $display("underflow at nout=%0d nsamp=%0d t=%0t", nout, nsamp, $time); end
  end

  // ---------------------------------------------------------------- DMA model
  task automatic send_beat(input [63:0] d, input bit last);
    @(posedge clk); #1; s_axis_valid = 1; s_axis_data = d; s_axis_last = last;
    do @(posedge clk); while (!s_axis_ready);
    #1; s_axis_valid = 0; s_axis_last = 0;
  endtask
  task automatic dma_packet(input int which, input bit bad_magic);
    int n; logic [63:0] w;
    n = which ? 500 : 900;
    send_beat({bad_magic ? 32'h12345678 : 32'h4F465458, 16'h0, 16'(n)}, 1'b0);
    for (int b = 0; b < n; b += 8) begin
      for (int k = 0; k < 8; k++) w[8*k +: 8] = (b + k < n) ? (which ? pkt1[b + k] : pkt0[b + k]) : 8'hEE;
      send_beat(w, (b + 8 >= n));
    end
  endtask

  // ---------------------------------------------------------------- AXI-Lite
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
  logic [31:0] w [16];
  task automatic read_status;
    logic [31:0] v;
    axi_write(12'h008, 1);
    repeat (40) begin axi_read(12'h008, v); if (v[0]) break; end
    if (!v[0]) begin errors++; $display("snapshot timeout"); end
    for (int k = 0; k < 16; k++) axi_read(12'h080 + 4 * k, w[k]);
  endtask

  logic [31:0] v;
  int t0;
  initial begin
    $readmemh("vec/txc_pkt0_in.mem", pkt0);
    $readmemh("vec/txc_pkt1_in.mem", pkt1);
    $readmemh("vec/txc_pkt0_exp.mem", exp0);
    $readmemh("vec/txc_pkt1_exp.mem", exp1);
    repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge aclk); aresetn = 1; repeat (4) @(posedge clk);
    axi_read(12'h000, v); if (v !== 32'h4F465458) begin errors++; $display("ID %08x", v); end
    axi_read(12'h010, v); if (v[15:0] !== 16'd16384) begin errors++; $display("gain reset %0d", v); end
    axi_read(12'h018, v); if (v[0] !== 1'b1) begin errors++; $display("enable reset"); end
    // enable = 0 blocks the stream; GAP is applied before the first packet as well
    axi_write(12'h018, 0); axi_write(12'h014, GAPS);
    checking = 1;
    fork
      begin dma_packet(0, 0); dma_packet(1, 1); dma_packet(1, 0); end
      begin
        repeat (GAPS * 3) @(posedge clk);
        if (dut.n_beat !== 0) begin errors++; $display("accepted beats while disabled: %0d", dut.n_beat); end
        axi_write(12'h018, 1);
      end
    join
    repeat (400000) begin @(posedge clk); if (nout == NA + NB) break; end
    repeat (300) @(posedge clk);
    if (nout !== NA + NB) begin errors++; $display("samples %0d != %0d", nout, NA + NB); end
    $display("gap between packets: %0d dac samples (cfg %0d)", first_act1 - last_act0, GAPS);
    if (first_act1 - last_act0 < GAPS) begin errors++; $display("gap too short"); end
    read_status();
    if (w[0][15:0] !== 2 || w[0][31:16] !== 2) begin errors++; $display("accepted/done %0d/%0d", w[0][15:0], w[0][31:16]); end
    if (w[2][31:16] !== 1) begin errors++; $display("bad headers %0d", w[2][31:16]); end
    if (w[2][15:0] !== 0 || w[1] !== 0) begin errors++; $display("underflow/overflow/trunc %08x %08x", w[2], w[1]); end
    if (w[15] !== 63) begin errors++; $display("dropped beats %0d (exp 63)", w[15]); end
    if (w[8] !== 1 + 113 + 1 + 63 + 1 + 63) begin errors++; $display("beats %0d", w[8]); end
    if (w[6] !== NA + NB) begin errors++; $display("active samples %0d != %0d", w[6], NA + NB); end
    if (w[7][15:0] == 0 || w[7][31:16] == 0) begin errors++; $display("output peak %08x", w[7]); end
    if (w[3] < w[6] || w[4] < 2 * w[3] - 4) begin errors++; $display("sample/clk counters %0d %0d", w[3], w[4]); end
    axi_write(12'h004, 2); read_status();
    if (w[8] > 4 || w[7] !== 0 || w[0][31:16] !== 0) begin errors++; $display("clear failed %0d %08x %08x", w[8], w[7], w[0]); end
    axi_write(12'h010, 16'd8192); axi_read(12'h010, v); if (v[15:0] !== 16'd8192) begin errors++; $display("gain readback"); end
    if (errors == 0) $display("TEST PASSED tb_phy_tx_axis_top (%0d samples bit-exact, framing/gap/regs ok)", nout);
    else $display("TEST FAILED tb_phy_tx_axis_top errors=%0d", errors);
    $finish;
  end
endmodule
