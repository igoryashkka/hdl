// File-driven TX testbench for the Python framework (phy_sim RtlSimTxBackend).
//   input : rtl_tx_in.mem  (NB lines, 3 hex digits {last,byte}: packets back to back, last marks the final byte of a packet)
//   output: rtl_tx_out.txt
//     META <nbytes> <npackets> <clks_per_sample>
//     I <hex8>          IQ sample {I16,Q16} while valid          Z <n>   n sample strobes without data (idle / underflow)
//     T <first_byte_clk> <last_byte_clk> <first_iq_clk> <last_iq_clk> <total_clks> <last_byte_of_first_packet_clk>
//     S <underflow_pulses> <overflow> <pkt_done_count>
// Generics: CODED (LDPC PHY), NB, NPKT, GAIN, CLKS_PER_SAMPLE, IDLE_LIMIT (strobes without data before the run ends), PKT_GAP_CLKS (idle clocks
// between the end of one packet's byte stream and the next one, i.e. the host-side packet pacing).
module tb_rtl_tx_file #(
  parameter int NB = 1100, parameter int NPKT = 1, parameter int GAIN = 16384, parameter int CLKS_PER_SAMPLE = 2,
  parameter int IDLE_LIMIT = 6000, parameter int PKT_GAP_CLKS = 0, parameter bit CODED = 1'b0
);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [8:0]  bytes_mem [NB];
  logic [15:0] gain = GAIN;
  logic s_valid = 0, s_ready, s_last = 0; logic [7:0] s_data = 0;
  logic iq_pull = 0, iq_valid, underflow, overflow, pkt_trunc, pkt_done, busy;
  logic signed [15:0] iq_re, iq_im;
  phy_tx_top #(.CODED(CODED)) dut (.clk, .rst, .gain, .s_valid, .s_ready, .s_data, .s_last, .iq_pull, .iq_re, .iq_im, .iq_valid,
                  .underflow, .overflow, .pkt_trunc, .pkt_done, .busy);

  int fd, cyc = 0, t_first_byte = -1, t_last_byte = -1, t_p0_last_byte = -1, t_first_iq = -1, t_last_iq = -1, n_under = 0, n_done = 0;
  int idle_run = 0, zrun = 0, ph = 0;
  bit started = 0, pull_en = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // sample strobe every CLKS_PER_SAMPLE clocks once the first sample is available (DAC would be idle before)
  always @(posedge clk) begin
    ph <= (ph + 1) % CLKS_PER_SAMPLE;
    iq_pull <= pull_en && (ph == 0);
  end
  always @(posedge clk) if (!rst) begin
    if (iq_valid && !pull_en) pull_en <= 1'b1;
    if (underflow) n_under++;
    if (pkt_done) n_done++;
    if (iq_pull) begin
      if (iq_valid) begin
        if (zrun > 0 && started) begin $fdisplay(fd, "Z %0d", zrun); end
        zrun = 0; started = 1; idle_run = 0;
        $fdisplay(fd, "I %04h%04h", iq_re & 16'hFFFF, iq_im & 16'hFFFF);
        if (t_first_iq < 0) t_first_iq = cyc;
        t_last_iq = cyc;
      end else if (started) begin
        zrun++; idle_run++;
      end
    end
  end

  initial begin
    fd = $fopen("rtl_tx_out.txt", "w");
    $readmemh("rtl_tx_in.mem", bytes_mem);
    $fdisplay(fd, "META %0d %0d %0d", NB, NPKT, CLKS_PER_SAMPLE);
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    @(posedge clk); #1;
    for (int i = 0; i < NB; i++) begin
      s_valid = 1; s_data = bytes_mem[i][7:0]; s_last = bytes_mem[i][8];
      if (t_first_byte < 0) t_first_byte = cyc;
      do @(posedge clk); while (!s_ready);          // accepted at this edge (pre-edge s_ready)
      t_last_byte = cyc;
      if (bytes_mem[i][8] && t_p0_last_byte < 0) t_p0_last_byte = cyc;
      #1;
      if (bytes_mem[i][8] && i != NB - 1) begin s_valid = 0; s_last = 0; repeat (PKT_GAP_CLKS) @(posedge clk); #1; end   // idle between packets
    end
    s_valid = 0; s_last = 0;
    while (!(n_done >= NPKT && idle_run >= IDLE_LIMIT / CLKS_PER_SAMPLE) && cyc < 40000000) @(posedge clk);
    $fdisplay(fd, "T %0d %0d %0d %0d %0d %0d", t_first_byte, t_last_byte, t_first_iq, t_last_iq, cyc, t_p0_last_byte);
    $fdisplay(fd, "S %0d %0d %0d", n_under, overflow, n_done);
    $fclose(fd);
    $finish;
  end
endmodule
