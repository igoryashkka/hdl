// Self-checking TB: phy_rx_pkt_out. Packets of 0, 1, 7, 8, 9 and 1100 random bytes are written into the RAM and committed;
// the AXI-stream (random ready) must carry header beats {A55A,01,flags,nbytes,seq}, {cfo_inc,nbest}, {angle[31:16],rssi,evm} and the
// payload packed LSB-first (zero padded), tlast only on the final beat, stable data/valid while stalled, seq/pkt_count
// counters, commit during a running transfer dropped (dropped counter), reset between packets.
module tb_phy_rx_pkt_out #(parameter bit V3 = 1'b0);
  localparam int NH = V3 ? 5 : 3;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic wr_en = 0; logic [12:0] wr_addr = 0; logic [7:0] wr_data = 0;
  logic commit = 0; logic [15:0] c_nbytes = 0; logic [7:0] c_flags = 0; logic [31:0] c_cfo_inc = 0, c_nbest = 0, c_angle = 0, c_evm = 0; logic [15:0] c_rssi = 0; logic [63:0] c_b3 = 0, c_b4 = 0;
  logic busy; logic [15:0] dropped, pkt_count;
  logic m_axis_valid, m_axis_ready = 0, m_axis_last; logic [63:0] m_axis_data;
  phy_rx_pkt_out #(.HDR_V3(V3)) dut (.*);

  byte payload [4400];
  int errors = 0, beat = 0, exp_beats = 0;
  logic [63:0] exp_data [600];
  bit exp_last [600];
  bit checking = 0;
  logic [63:0] held; bit has_held = 0;

  always @(posedge clk) if (checking && !rst) begin
    if (has_held && !(m_axis_valid && m_axis_data === held)) begin errors++; $display("stream changed/dropped while stalled"); end
    has_held <= m_axis_valid && !m_axis_ready; held <= m_axis_data;
    if (m_axis_valid && m_axis_ready) begin
      if (beat >= exp_beats) begin errors++; $display("extra beat %0d", beat); end
      else begin
        if (m_axis_data !== exp_data[beat]) begin errors++; if (errors < 10) $display("beat %0d got %016x exp %016x", beat, m_axis_data, exp_data[beat]); end
        if (m_axis_last !== exp_last[beat]) begin errors++; $display("tlast wrong at beat %0d", beat); end
      end
      beat++;
    end
  end
  always @(posedge clk) m_axis_ready <= ($urandom_range(0, 9) < 5);

  task automatic run_packet(input int n, input int seq_exp);
    logic [63:0] w;
    int nb;
    for (int i = 0; i < n; i++) payload[i] = $urandom;
    for (int i = 0; i < n; i++) begin @(posedge clk); #1; wr_en = 1; wr_addr = i; wr_data = payload[i]; end
    @(posedge clk); #1; wr_en = 0;
    c_nbytes = n; c_flags = 8'h05; c_cfo_inc = $urandom; c_nbest = $urandom; c_angle = $urandom; c_rssi = $urandom; c_evm = $urandom; c_b3 = {$urandom, $urandom}; c_b4 = {$urandom, $urandom};
    nb = NH + (n + 7) / 8;
    exp_beats = nb;
    exp_data[0] = {16'hA55A, V3 ? 8'h03 : 8'h02, 8'h05, 16'(n), 16'(seq_exp)};
    exp_data[1] = {c_cfo_inc, c_nbest};
    exp_data[2] = {c_angle[31:16], c_rssi, c_evm};
    if (V3) begin exp_data[3] = c_b3; exp_data[4] = c_b4; end
    for (int b = 0; b < (n + 7) / 8; b++) begin
      w = '0;
      for (int k = 0; k < 8; k++) if (b * 8 + k < n) w[8*k +: 8] = payload[b * 8 + k];
      exp_data[NH + b] = w;
    end
    for (int b = 0; b < nb; b++) exp_last[b] = (b == nb - 1);
    beat = 0; checking = 1;
    @(posedge clk); #1; commit = 1; @(posedge clk); #1; commit = 0;
    // commit while busy must be dropped
    repeat (3) @(posedge clk); #1; commit = 1; c_nbytes = 5; @(posedge clk); #1; commit = 0; c_nbytes = n;
    while (beat < nb) @(posedge clk);
    repeat (12) @(posedge clk);
    if (busy) begin errors++; $display("busy after packet"); end
  endtask

  initial begin
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    run_packet(1100, 0);
    run_packet(0, 1);
    run_packet(1, 2);
    run_packet(7, 3);
    run_packet(8, 4);
    run_packet(9, 5);
    if (dropped !== 16'd6) begin errors++; $display("dropped %0d (exp 6)", dropped); end
    if (pkt_count !== 16'd6) begin errors++; $display("pkt_count %0d (exp 6)", pkt_count); end
    // reset clears seq
    checking = 0; @(posedge clk); #1; rst = 1; repeat (3) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    run_packet(16, 0);
    if (errors == 0) $display("TEST PASSED tb_phy_rx_pkt_out V3=%0d", V3);
    else $display("TEST FAILED tb_phy_rx_pkt_out errors=%0d", errors);
    $finish;
  end
endmodule
