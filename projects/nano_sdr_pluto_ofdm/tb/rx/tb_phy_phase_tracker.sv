// Self-checking TB: phy_phase_tracker vs python/rx_fixed_ref.py::cpe_track (bit-exact derotated data bins and bit-exact
// CPE angle). 6 symbols with common phase rotations 0, +90, -90, ~180, 0.37 rad, -2.9 rad plus noise; each symbol is 1200
// active bins (1100 data + 100 pilots), valid gaps with garbage on idle cycles, output first/last flags, 1100 outputs per
// symbol, no overrun, reset in the middle of a symbol followed by a clean run.
module tb_phy_phase_tracker #(parameter bit SLOPE = 1'b0);
  localparam int NA = 1200, ND = 1100, NF = 6, MAXN = 16384, NX = SLOPE ? 3 : 2;      // per frame: ND data words, angle, l1 (, slope)
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [33:0] stim [MAXN];
  logic [31:0] expd [NF * (ND + NX)];
  logic [31:0] slope_o; logic slope_valid;
  logic in_valid = 0, in_first = 0, in_last = 0; logic signed [15:0] in_re = 0, in_im = 0;
  logic out_valid, out_first, out_last, angle_valid, busy, overrun, l1_valid; logic [23:0] l1_val; logic signed [15:0] out_re, out_im; logic [31:0] angle_o;
  phy_phase_tracker #(.SLOPE(SLOPE)) dut (.*);

  int errors = 0, nout = 0, nang = 0, nl1 = 0, nsl = 0, frame = 0;
  bit checking = 0;
  always @(posedge clk) if (checking && !rst) begin
    if (out_valid) begin
      int idx;
      idx = frame * (ND + NX) + (nout % ND);
      if ({out_re, out_im} !== expd[idx]) begin
        errors++; if (errors < 10) $display("DATA mismatch frame %0d #%0d got %04x/%04x exp %08x", frame, nout % ND, out_re & 16'hFFFF, out_im & 16'hFFFF, expd[idx]);
      end
      if (out_first !== (nout % ND == 0) || out_last !== (nout % ND == ND - 1)) begin errors++; if (errors < 10) $display("flag mismatch frame %0d at %0d", frame, nout % ND); end
      nout++;
      if (nout % ND == 0) frame++;
    end
    if (angle_valid) begin
      if (angle_o !== expd[nang * (ND + NX) + ND]) begin errors++; $display("ANGLE mismatch frame %0d got %08x exp %08x", nang, angle_o, expd[nang * (ND + NX) + ND]); end
      nang++;
    end
    if (slope_valid && SLOPE) begin
      if (slope_o !== expd[nsl * (ND + NX) + ND + 2]) begin errors++; $display("SLOPE mismatch frame %0d got %08x exp %08x", nsl, slope_o, expd[nsl * (ND + NX) + ND + 2]); end
      nsl++;
    end
    if (l1_valid) begin
      if ({8'd0, l1_val} !== expd[nl1 * (ND + NX) + ND + 1]) begin errors++; $display("L1 mismatch frame %0d got %0d exp %0d", nl1, l1_val, expd[nl1 * (ND + NX) + ND + 1]); end
      nl1++;
    end
  end

  task automatic play_frame(input int f);
    for (int i = 0; i < NA; i++) begin
      while ($urandom_range(0, 9) < 2) begin @(posedge clk); #1; in_valid = 0; in_first = $urandom; in_last = $urandom; in_re = $urandom; in_im = $urandom; end
      @(posedge clk); #1;
      in_valid = 1; in_first = stim[f * NA + i][33]; in_last = stim[f * NA + i][32]; in_re = stim[f * NA + i][31:16]; in_im = stim[f * NA + i][15:0];
    end
    @(posedge clk); #1; in_valid = 0; in_first = 0; in_last = 0;
    repeat (2600) @(posedge clk);     // symbol spacing >> read-out time (as the CP + frame buffer pacing in the real RX)
  endtask

  initial begin
    for (int i = 0; i < MAXN; i++) stim[i] = 34'bx;
    if (SLOPE) begin $readmemh("vec/cps_in.mem", stim); $readmemh("vec/cps_exp.mem", expd); end
    else begin $readmemh("vec/cpe_in.mem", stim); $readmemh("vec/cpe_exp.mem", expd); end
    repeat (4) @(posedge clk); #1; rst = 0; repeat (2) @(posedge clk);
    // reset in the middle of a symbol
    for (int i = 0; i < 700; i++) begin @(posedge clk); #1; in_valid = 1; in_first = (i == 0); in_re = 16'sd1000; in_im = 16'sd1000; end
    @(posedge clk); #1; rst = 1; in_valid = 0; repeat (3) @(posedge clk); #1; rst = 0; repeat (3) @(posedge clk);
    checking = 1;
    for (int f = 0; f < NF; f++) play_frame(f);
    if (nout !== NF * ND) begin errors++; $display("outputs %0d != %0d", nout, NF * ND); end
    if (nang !== NF) begin errors++; $display("angles %0d != %0d", nang, NF); end
    if (SLOPE && nsl !== NF) begin errors++; $display("slope pulses %0d != %0d", nsl, NF); end
    if (nl1 !== NF) begin errors++; $display("l1 pulses %0d != %0d", nl1, NF); end
    if (overrun) begin errors++; $display("overrun flagged"); end
    if (errors == 0) $display("TEST PASSED tb_phy_phase_tracker SLOPE=%0d (%0d symbols, %0d data bins)", SLOPE, NF, nout);
    else $display("TEST FAILED tb_phy_phase_tracker errors=%0d", errors);
    $finish;
  end
endmodule
