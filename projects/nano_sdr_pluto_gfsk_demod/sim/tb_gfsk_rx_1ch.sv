// ***************************************************************************
// Testbench: packet 0 of capture_300MB.iq (Fs 4.5 MS/s, fc_bb = -686.472 kHz).
// Expected = bytes of the C decoder (hopdet) for the same packet:
//   length 13, network 00, frame ...; 16 bytes after sync, PN9-dewhitened.
// Run from the sim/ directory (files are read relative to it).
// ***************************************************************************
`timescale 1ns/100ps

module tb_gfsk_rx_1ch;
  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;                      // 100 MHz (timing is irrelevant for the functional test)

  logic               in_valid = 1'b0;
  logic signed [15:0] i_in = '0, q_in = '0;
  logic        [31:0] phase_inc = 32'hd8f286e2;   // fc_bb = -686472 Hz
  logic               frame_start, byte_valid, frame_done;
  logic        [7:0]  byte_out, frame_len;

  gfsk_rx_1ch dut (
    .clk, .rst, .in_valid, .i_in, .q_in, .phase_inc,
    .frame_start, .byte_valid, .byte_out, .frame_done, .frame_len
  );

  // packet selection from cfg.txt (defaults: packet 0 when cfg.txt is absent)
  string iqfile = "pkt0_iq.txt", expfile = "";
  logic [7:0] EXP [0:15] = '{
    8'h0d, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'he9, 8'h0d,
    8'h1f, 8'he9, 8'h07, 8'h04, 8'h00, 8'h66, 8'hf6, 8'h1a};

  int got = 0, errs = 0, starts = 0, samples = 0;
  logic [7:0] rx [0:63];

  initial begin : stim
    int fd, n, a, b;
    // run configuration: cfg.txt = <iq file> / <expected-bytes file> / <phase_inc hex>
    int cfd = $fopen("cfg.txt", "r");
    if (cfd != 0) begin
      void'($fscanf(cfd, "%s\n", iqfile));
      void'($fscanf(cfd, "%s\n", expfile));
      void'($fscanf(cfd, "%h\n", phase_inc));
      $fclose(cfd);
      $readmemh(expfile, EXP);
    end
    fd = $fopen(iqfile, "r");
    if (fd == 0) begin
      $display("ERROR: cannot open pkt0_iq.txt");
      $finish;
    end
    repeat (4) @(posedge clk);
    rst = 1'b0;
    while (!$feof(fd)) begin
      n = $fscanf(fd, "%d %d\n", a, b);
      if (n == 2) begin
        @(posedge clk);
        i_in     <= 16'(a);
        q_in     <= 16'(b);
        in_valid <= 1'b1;
        samples++;
      end
    end
    @(posedge clk);
    in_valid <= 1'b0;
    repeat (2000) @(posedge clk);            // let the last bits and bytes drain
    $fclose(fd);
    report();
    $finish;
  end

  always @(posedge clk) begin
    if (frame_start) starts++;
    if (byte_valid) begin
      rx[got] <= byte_out;
      got++;
    end
  end

  task automatic report();
    $display("samples fed: %0d", samples);
    $display("sync found : %0d time(s)", starts);
    $display("bytes      : %0d (length byte = %0d)", got, rx[0]);
    for (int k = 0; k < 16; k++) begin
      if (k < got && rx[k] !== EXP[k]) begin
        errs++;
        $display("  byte %0d: got %h expected %h", k, rx[k], EXP[k]);
      end
    end
    if (starts == 1 && got >= 16 && errs == 0)
      $display("RESULT: PASS (first 16 bytes match the C decoder)");
    else
      $display("RESULT: FAIL (starts=%0d bytes=%0d mismatches=%0d)", starts, got, errs);
  endtask
endmodule
