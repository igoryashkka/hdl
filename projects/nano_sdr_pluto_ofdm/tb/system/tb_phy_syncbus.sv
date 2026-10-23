// System TB: phy_syncbus leader + follower on unrelated clocks (122.88 MHz and 122.88 MHz + 37 ppm, random phase), wired like
// the JP5 cable (SCLK / MOSI driven by the leader, UP by the follower, pull-up when released). Frames from python/bf_ref.py via
// generate_vectors_bf.py: PARAMS, SET_EPOCH, an unknown type, two corrupted frames; plus a frame preceded by junk bytes (bit hunt)
// and a frame with the follower switched off (no answer -> resp_bad). Repeated for div = 12, 10, 30.
// Checks: follower rx_ok / rx_bad per frame, rx_last == type..payload, crc error counter; leader resp_ok, response fields
// (type 0x81, seq echo, len 16, status / epoch / ts as presented, crc_err), UP Hi-Z outside the response.
module tb_phy_syncbus;
  localparam int TXMAX = 48, RXMAX = 48, RL = 19;
  logic lclk = 0, fclk = 0, rst = 1;
  always #4.069 lclk = ~lclk;
  initial begin #3.3; forever #4.06915 fclk = ~fclk; end

  logic [1:0] lrole = 2'd1, frole = 2'd2; logic [7:0] div = 8'd12;
  logic tx_start = 0; logic [5:0] tx_len = 0; logic [8*TXMAX-1:0] tx_buf = '0;
  logic l_busy, resp_ok, resp_bad; logic [8*RL-1:0] resp_last;
  logic rx_ok, rx_bad; logic [8*RXMAX-1:0] rx_last, rx_work; logic [15:0] rx_crc_err;
  logic [15:0] resp_status = 0; logic [31:0] resp_epoch = 0; logic [63:0] resp_ts = 0;
  wire sclk_w, mosi_w, up_w;
  logic l_sclk_o, l_sclk_t, l_mosi_o, l_mosi_t, l_up_o, l_up_t, f_sclk_o, f_sclk_t, f_mosi_o, f_mosi_t, f_up_o, f_up_t;
  assign sclk_w = l_sclk_t ? 1'bz : l_sclk_o;
  assign mosi_w = l_mosi_t ? 1'bz : l_mosi_o;
  assign up_w   = f_up_t ? 1'bz : f_up_o;
  pullup (sclk_w); pullup (mosi_w); pullup (up_w);

  phy_syncbus u_l (.clk(lclk), .rst, .role(lrole), .div, .tx_start, .tx_len, .tx_buf, .tx_busy(l_busy), .resp_ok, .resp_bad, .resp_last,
    .rx_ok(), .rx_bad(), .rx_last(), .rx_work(), .rx_crc_err(), .resp_status(16'd0), .resp_epoch(32'd0), .resp_ts(64'd0),
    .sclk_i(sclk_w), .mosi_i(mosi_w), .up_i(up_w), .sclk_o(l_sclk_o), .mosi_o(l_mosi_o), .up_o(l_up_o),
    .sclk_t(l_sclk_t), .mosi_t(l_mosi_t), .up_t(l_up_t));
  phy_syncbus u_f (.clk(fclk), .rst, .role(frole), .div, .tx_start(1'b0), .tx_len(6'd0), .tx_buf('0), .tx_busy(), .resp_ok(), .resp_bad(),
    .resp_last(), .rx_ok, .rx_bad, .rx_last, .rx_work, .rx_crc_err, .resp_status, .resp_epoch, .resp_ts,
    .sclk_i(sclk_w), .mosi_i(mosi_w), .up_i(up_w), .sclk_o(f_sclk_o), .mosi_o(f_mosi_o), .up_o(f_up_o),
    .sclk_t(f_sclk_t), .mosi_t(f_mosi_t), .up_t(f_up_t));

  logic [11:0] vec [2048];
  int errors = 0, n_rxok = 0, n_rxbad = 0, n_rok = 0, n_rbad = 0, n_bad_exp = 0, n_frames = 0;
  always @(posedge fclk) begin if (rx_ok) n_rxok++; if (rx_bad) n_rxbad++; end
  always @(posedge lclk) begin if (resp_ok) n_rok++; if (resp_bad) n_rbad++; end
  // the follower may drive UP only between the end of a frame and the end of its response (checked loosely: never while SCLK runs a frame)
  always @(posedge fclk) if (!f_up_t && u_f.fst == u_f.F_RX) begin errors++; $display("UP driven during a frame"); end

  task automatic send(input logic [7:0] b [], input bit good, input bit answer, input int idx);
    int ok0, bad0, rok0, rbad0;
    ok0 = n_rxok; bad0 = n_rxbad; rok0 = n_rok; rbad0 = n_rbad;
    resp_status = 16'hBEEF ^ 16'(idx); resp_epoch = 32'h1000_0000 + idx; resp_ts = 64'h0123_4567_89AB_0000 + idx;
    tx_buf = '0;
    foreach (b[i]) tx_buf[8*i +: 8] = b[i];
    @(posedge lclk); #1; tx_len = 6'(b.size()); tx_start = 1; @(posedge lclk); #1; tx_start = 0;
    @(posedge lclk); #1;
    wait (!l_busy); repeat (5) @(posedge lclk);
    n_frames++;
    if (!answer) begin
      if (n_rbad != rbad0 + 1 || n_rok != rok0) begin errors++; $display("frame %0d: expected resp_bad without a follower", idx); end
      return;
    end
    if (good) begin
      int off;
      off = (b[0] == 8'hA5) ? 0 : 2;                                        // junk-prefixed frame: sync after 2 bytes
      if (n_rxok != ok0 + 1 || n_rxbad != bad0) begin errors++; $display("frame %0d: rx_ok not seen", idx); end
      for (int i = 0; i < 3 + b[off + 4]; i++)
        if (rx_last[8*i +: 8] !== b[off + 2 + i]) begin errors++; $display("frame %0d: rx byte %0d %02x != %02x", idx, i, rx_last[8*i +: 8], b[off + 2 + i]); break; end
    end else begin
      n_bad_exp++;
      if (n_rxbad != bad0 + 1 || n_rxok != ok0) begin errors++; $display("frame %0d: rx_bad not seen", idx); end
    end
    if (rx_crc_err !== 16'(n_bad_exp)) begin errors++; $display("crc_err %0d != %0d", rx_crc_err, n_bad_exp); end
    if (n_rok != rok0 + 1) begin errors++; $display("frame %0d: no good response", idx); return; end
    if (resp_last[7:0] !== 8'h81 || resp_last[23:16] !== 8'd16 || resp_last[39:24] !== resp_status || resp_last[55:40] !== 16'(n_bad_exp)
        || resp_last[87:56] !== resp_epoch || resp_last[151:88] !== resp_ts) begin
      errors++; $display("frame %0d: response fields %h", idx, resp_last);
    end
    if (good && resp_last[15:8] !== b[(b[0] == 8'hA5) ? 3 : 5]) begin errors++; $display("frame %0d: seq echo %02x", idx, resp_last[15:8]); end
  endtask

  initial begin
    int p, n, idx;
    logic [7:0] b [];
    $readmemh("vec/bf_bus_frames.mem", vec);
    repeat (5) @(posedge lclk); rst = 0; repeat (5) @(posedge lclk);
    for (int pass = 0; pass < 3; pass++) begin
      div = (pass == 0) ? 8'd12 : (pass == 1) ? 8'd10 : 8'd30;
      p = 0; idx = 0;
      while (vec[p] !== 12'hFFF) begin
        n = vec[p][7:0];
        b = new[n];
        for (int i = 0; i < n; i++) b[i] = vec[p + 1 + i][7:0];
        send(b, vec[p][8], 1'b1, idx);
        p += n + 1; idx++;
      end
      // junk before the sync word: the follower hunts for A5 5A
      p = 0;
      n = vec[p][7:0];
      b = new[n + 2]; b[0] = 8'h13; b[1] = 8'h37;
      for (int i = 0; i < n; i++) b[i + 2] = vec[p + 1 + i][7:0];
      send(b, 1'b1, 1'b1, 100);
      // follower off: nobody answers (pull-up) -> resp_bad
      frole = 2'd0; repeat (10) @(posedge fclk);
      b = new[n]; for (int i = 0; i < n; i++) b[i] = vec[p + 1 + i][7:0];
      send(b, 1'b1, 1'b0, 101);
      frole = 2'd2; repeat (10) @(posedge fclk); n_bad_exp = 0;               // role change resets the follower (error counter)
    end
    if (errors == 0) $display("TEST PASSED tb_phy_syncbus (%0d frames over 3 SCLK rates, %0d good responses)", n_frames, n_rok);
    else $display("TEST FAILED tb_phy_syncbus errors=%0d", errors);
    $finish;
  end
endmodule
