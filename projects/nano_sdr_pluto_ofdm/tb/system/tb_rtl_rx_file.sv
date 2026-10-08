// File-driven RX testbench for the Python framework (phy_sim RtlSimRxBackend).
//   input : rtl_rx_in.mem  (NS lines, hex {I16,Q16}, ADC-level samples)
//   output: rtl_rx_out.txt (text log parsed by Python)
//     META <ns> <nsyms> <clks_per_sample> <first_sample_clk>
//     B <hex64> <last> <clk>      accepted AXI-stream beat of phy_rx_top
//     E <n_best> <n_decl> <clk>   detector event          C <cfo_inc> <clk>  NCO increment
//     Q <re> <im>                 equalised / derotated data bins (DEBUG=1)
//     W <s> <hex40>               channel weights of the packet (DEBUG=1)
//     S <det> <pkt> <drop> <wd> <flags> <total_clks>
// Generics: NS, NSYMS, RMIN, GAIN_SH, CLKS_PER_SAMPLE (2 = l_clk 61.44 MHz for 30.72 MS/s), IDLE_LIMIT, DEBUG.
module tb_rtl_rx_file #(
  parameter int NS = 1000, parameter int NSYMS = 2, parameter int RMIN = 262144, parameter int GAIN_SH = 0,
  parameter int CLKS_PER_SAMPLE = 2, parameter int IDLE_LIMIT = 60000, parameter int DEBUG = 1
);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [31:0] samples [NS];
  logic [7:0]  cfg_nsyms = NSYMS;
  logic [31:0] cfg_rmin = RMIN;
  logic signed [3:0] cfg_gain_sh = GAIN_SH;
  logic in_valid = 0; logic signed [15:0] in_i = 0, in_q = 0;
  logic m_axis_valid, m_axis_ready = 0, m_axis_last; logic [63:0] m_axis_data;
  logic [15:0] st_det_count, st_pkt_count, st_drop_count, st_wd_count; logic [7:0] st_flags; logic st_busy;
  logic cfg_mmse = 1; logic [4:0] cfg_max_iter = 10; logic signed [12:0] cfg_bad_thr = 106; logic cfg_ft_en = 1; logic [7:0] cfg_tau_tgt = 56;
  logic signed [19:0] st_tau_q8; logic signed [7:0] st_w0_adj;
  logic [15:0] st_snr_avg, st_snr_min, st_bad, st_noise, st_cw_count, st_cwfail_count; logic [7:0] st_ldpc_fail; logic [4:0] st_ldpc_imax; logic [11:0] st_ldpc_isum;
  logic [15:0] st_rssi, st_angle, st_seq; logic [31:0] st_evm, st_cfo_inc, st_nbest; logic st_pkt_pulse;
  phy_rx_top dut (.*);

  int fd, cyc = 0, t_first = -1, t_last_beat = 0, nbeat = 0;
  always @(posedge clk) cyc <= cyc + 1;
  always @(posedge clk) m_axis_ready <= ($urandom_range(0, 9) < 8);

  // beats
  always @(posedge clk) if (!rst) begin
    if (m_axis_valid && m_axis_ready) begin
      $fdisplay(fd, "B %016h %0d %0d", m_axis_data, m_axis_last, cyc);
      t_last_beat = cyc; nbeat++;
    end
    if (dut.ev_valid) $fdisplay(fd, "E %0d %0d %0d", dut.ev_n_best, dut.ev_n_decl, cyc);
    if (dut.cfo_done) $fdisplay(fd, "C %0d %0d", dut.cfo_inc, cyc);
    if (DEBUG != 0) begin
      if (dut.pt_valid) $fdisplay(fd, "Q %0d %0d", $signed(dut.pt_re), $signed(dut.pt_im));
      if (dut.ce_done) for (int s = 0; s < 1200; s++) $fdisplay(fd, "W %0d %010h", s, dut.u_chest.wram[s]);
    end
  end

  initial begin
    fd = $fopen("rtl_rx_out.txt", "w");
    $readmemh("rtl_rx_in.mem", samples);
    repeat (6) @(posedge clk); #1; rst = 0; repeat (4) @(posedge clk);
    t_first = cyc + 1;
    $fdisplay(fd, "META %0d %0d %0d %0d", NS, NSYMS, CLKS_PER_SAMPLE, t_first);
    for (int n = 0; n < NS; n++) begin
      @(posedge clk); #1; in_valid = 1; in_i = samples[n][31:16]; in_q = samples[n][15:0];
      for (int k = 1; k < CLKS_PER_SAMPLE; k++) begin @(posedge clk); #1; in_valid = 0; end
    end
    @(posedge clk); #1; in_valid = 0;
    // run until the output has been idle for IDLE_LIMIT clocks after the stream ended (or the packet pipeline is idle)
    begin
      int idle_start = cyc;
      while (cyc - ((t_last_beat > idle_start) ? t_last_beat : idle_start) < IDLE_LIMIT) @(posedge clk);
    end
    $fdisplay(fd, "S %0d %0d %0d %0d %0d %0d", st_det_count, st_pkt_count, st_drop_count, st_wd_count, st_flags, cyc);
    $fclose(fd);
    $finish;
  end
endmodule
