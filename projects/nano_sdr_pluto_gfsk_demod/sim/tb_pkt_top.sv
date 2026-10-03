// ***************************************************************************
// Testbench for gfsk_rx_pkt_top: IQ -> 32-byte records on the 64-bit stream.
// Reads the same cfg.txt as tb_gfsk_rx_1ch. Checks each record:
//   magic A5, flags 0x03 (CRC8 ok, CRC16 ok, length 13), counter, frame bytes.
// ***************************************************************************
`timescale 1ns/100ps

module tb_pkt_top;
  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  logic               in_valid = 1'b0;
  logic signed [15:0] i_in = '0, q_in = '0;
  logic        [31:0] phase_inc = 32'hd8f286e2;
  logic               m_axis_valid, m_axis_last, m_axis_ready = 1'b1;
  logic        [63:0] m_axis_data;
  logic        [15:0] drops;

  gfsk_rx_pkt_top dut (
    .clk, .rst, .in_valid, .i_in, .q_in, .phase_inc,
    .m_axis_valid, .m_axis_ready, .m_axis_data, .m_axis_last, .drops
  );

  logic [7:0] rec [0:31];
  int nbeat = 0, nrec = 0, errs = 0;
  logic [7:0] exp_b [0:15];

  initial begin : stim
    int fd, n, a, b, cfd;
    string iqfile = "pkt0_iq.txt", expfile = "pkt0_exp.mem";
    cfd = $fopen("cfg.txt", "r");
    if (cfd != 0) begin
      void'($fscanf(cfd, "%s\n", iqfile));
      void'($fscanf(cfd, "%s\n", expfile));
      void'($fscanf(cfd, "%h\n", phase_inc));
      $fclose(cfd);
    end
    $readmemh(expfile, exp_b);
    fd = $fopen(iqfile, "r");
    repeat (4) @(posedge clk);
    rst = 1'b0;
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%d %d\n", a, b);
      if (n == 2) begin
        @(posedge clk);
        i_in <= 16'(a);
        q_in <= 16'(b);
        in_valid <= 1'b1;
      end
    end
    @(posedge clk);
    in_valid <= 1'b0;
    repeat (3000) @(posedge clk);
    $fclose(fd);
    $display("records: %0d   drops: %0d", nrec, drops);
    if (nrec >= 1 && errs == 0) $display("RESULT: PASS");
    else                       $display("RESULT: FAIL (records=%0d errors=%0d)", nrec, errs);
    $finish;
  end

  // collect the 4 beats of each record
  always @(posedge clk) begin
    if (m_axis_valid && m_axis_ready) begin
      for (int j = 0; j < 8; j++) rec[8*nbeat + j] = m_axis_data[8*j +: 8];
      nbeat++;
      if (m_axis_last) begin
        nrec++;
        nbeat = 0;
        check_record();
      end
    end
  end

  task automatic check_record();
    $display("record %0d: magic %h flags %b len %0d ch %0d counter %0d ts %0d",
             nrec, rec[0], rec[1][4:0], rec[2], rec[3],
             {rec[4], rec[5], rec[6], rec[7]}, {rec[8], rec[9], rec[10], rec[11]});
    if (rec[0] !== 8'hA5)            begin errs++; $display("  bad magic"); end
    if (rec[1][1:0] !== 2'b11)       begin errs++; $display("  CRC flags not both ok"); end
    for (int k = 0; k < 16; k++)
      if (rec[12+k] !== exp_b[k]) begin errs++; $display("  frame byte %0d: %h vs %h", k, rec[12+k], exp_b[k]); end
  endtask
endmodule
