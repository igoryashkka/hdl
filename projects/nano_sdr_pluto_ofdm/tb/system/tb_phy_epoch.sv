// System TB: phy_epoch on two boards. Leader on 122.88 MHz, follower on 122.88 MHz + 37 ppm with a different strobe phase;
// DAC strobe every 4th clock on each board; EPOCH wire with 3 ns delay.
// Checks: leader tick period = `period` strobes; follower tick within +-1 clock (8.2 ns) of the leader tick; tick_phase = measured
// clocks from the tick to the first strobe on each board; since = index of the last strobe; strobe_log2 = 2; force_tick fires at
// the next strobe; set_epoch -> equal epoch numbers; pending sets applied on both boards at the same tick (target = n, next, past
// (late_cnt), overwritten pending -> only the last applies); stale after stale_lim ticks without apply.
module tb_phy_epoch;
  localparam int PW = 32;
  logic lclk = 0, fclk = 0, rst = 1;
  always #4.069 lclk = ~lclk;
  initial begin #1.7; forever #4.06915 fclk = ~fclk; end
  logic [1:0] lph = 0, fph = 0;
  logic ls, fs;
  always @(posedge lclk) lph <= lph + 1'b1;
  always @(posedge fclk) fph <= fph + 1'b1;
  assign ls = (lph == 2'd1) && !rst;
  assign fs = (fph == 2'd3) && !rst;

  logic [31:0] period = 32'd400;
  logic l_force = 0, f_force = 0, l_set = 0, f_set = 0, l_we = 0, f_we = 0;
  logic [31:0] set_val = 0, l_tgt = 0, f_tgt = 0; logic [PW-1:0] l_d = 0, f_d = 0; logic [7:0] stale_lim = 0;
  logic l_pin, f_pin_unused; wire ep_wire;
  assign #3 ep_wire = l_pin;
  logic l_tick, f_tick, l_apply, f_apply, l_pv, f_pv, l_stale, f_stale, l_p2, f_p2;
  logic [31:0] l_num, f_num, l_since, f_since; logic [63:0] l_sc, f_sc, l_ts, f_ts; logic [7:0] l_tp, f_tp; logic [3:0] l_lg, f_lg;
  logic [PW-1:0] l_act, f_act; logic [15:0] l_ac, f_ac, l_lc, f_lc;

  phy_epoch #(.PW(PW)) u_l (.clk(lclk), .rst, .strobe(ls), .role(2'd1), .period, .force_tick(l_force), .ep_pin_i(1'b0), .ep_pin_o(l_pin),
    .set_epoch(l_set), .set_epoch_val(set_val), .pend_we(l_we), .pend_target(l_tgt), .pend_data(l_d), .stale_lim,
    .tick(l_tick), .epoch_num(l_num), .sample_cnt(l_sc), .ts_tick(l_ts), .since(l_since), .tick_phase(l_tp), .strobe_log2(l_lg),
    .strobe_p2(l_p2), .active(l_act), .apply(l_apply), .pend_valid(l_pv), .apply_cnt(l_ac), .late_cnt(l_lc), .stale(l_stale));
  phy_epoch #(.PW(PW)) u_f (.clk(fclk), .rst, .strobe(fs), .role(2'd2), .period, .force_tick(f_force), .ep_pin_i(ep_wire), .ep_pin_o(f_pin_unused),
    .set_epoch(f_set), .set_epoch_val(set_val), .pend_we(f_we), .pend_target(f_tgt), .pend_data(f_d), .stale_lim,
    .tick(f_tick), .epoch_num(f_num), .sample_cnt(f_sc), .ts_tick(f_ts), .since(f_since), .tick_phase(f_tp), .strobe_log2(f_lg),
    .strobe_p2(f_p2), .active(f_act), .apply(f_apply), .pend_valid(f_pv), .apply_cnt(f_ac), .late_cnt(f_lc), .stale(f_stale));

  int errors = 0, nl = 0, nf = 0, l_strobes = 0, lt_cnt = -1;
  realtime t_lt = 0, t_ft = 0, t_la = 0, t_fa = 0;
  // leader period and tick phase / since checks (both boards)
  int l_tp_meas = -1, f_tp_meas = -1, l_cyc_since = 0, f_cyc_since = 0;
  bit l_wait = 0, f_wait = 0;
  always @(posedge lclk) if (!rst) begin
    if (l_tick) begin
      nl++; t_lt = $realtime;
      if (lt_cnt >= 0 && lt_cnt != period && !l_force) begin errors++; $display("leader period %0d strobes != %0d", lt_cnt, period); end
      lt_cnt = 0; l_wait = 1; l_cyc_since = 0;
      if (ls) begin l_tp_meas = 0; l_wait = 0; end
    end else begin
      if (l_wait) l_cyc_since++;
      if (ls && l_wait) begin l_tp_meas = l_cyc_since; l_wait = 0; end
    end
    if (ls && lt_cnt >= 0) lt_cnt++;
  end
  always @(posedge fclk) if (!rst) begin
    if (f_tick) begin
      nf++; t_ft = $realtime; f_wait = 1; f_cyc_since = 0;
      if (fs) begin f_tp_meas = 0; f_wait = 0; end
    end else begin
      if (f_wait) f_cyc_since++;
      if (fs && f_wait) begin f_tp_meas = f_cyc_since; f_wait = 0; end
    end
  end
  always @(negedge lclk) if (!rst && l_tp_meas >= 0 && !u_l.tp_run && l_tp !== 8'(l_tp_meas)) begin errors++; $display("leader tick_phase %0d != %0d", l_tp, l_tp_meas); l_tp_meas = -1; end
  always @(negedge fclk) if (!rst && f_tp_meas >= 0 && !u_f.tp_run && f_tp !== 8'(f_tp_meas)) begin errors++; $display("follower tick_phase %0d != %0d", f_tp, f_tp_meas); f_tp_meas = -1; end
  always @(posedge fclk) if (f_tick && t_lt > 0) begin
    if ($realtime - t_lt < -8.2 || $realtime - t_lt > 8.2) begin errors++; $display("follower tick %0.1f ns after the leader", $realtime - t_lt); end
  end
  always @(posedge lclk) if (l_apply) t_la = $realtime;
  always @(posedge fclk) if (f_apply) t_fa = $realtime;

  task automatic both_pend(input logic [31:0] tgt, input logic [PW-1:0] d);
    @(posedge lclk); #1; l_we = 1; l_tgt = tgt; l_d = d; @(posedge lclk); #1; l_we = 0;
    repeat (37) @(posedge fclk); #1; f_we = 1; f_tgt = tgt; f_d = d; @(posedge fclk); #1; f_we = 0;
  endtask
  task automatic wait_ticks(input int n);
    int t0; t0 = nl; while (nl < t0 + n) @(posedge lclk); repeat (20) @(posedge lclk);
  endtask

  initial begin
    repeat (10) @(posedge lclk); rst = 0;
    wait_ticks(3);
    if (nf < 2) begin errors++; $display("follower does not tick"); end
    if (l_lg !== 4'd2 || f_lg !== 4'd2 || !l_p2 || !f_p2) begin errors++; $display("strobe_log2 %0d %0d", l_lg, f_lg); end
    // since: index of the last strobe
    @(posedge lclk); #1;
    if (l_since !== 32'(lt_cnt - 1)) begin errors++; $display("since %0d != %0d", l_since, lt_cnt - 1); end
    // epoch numbers
    @(posedge lclk); #1; set_val = 32'd1000; l_set = 1; @(posedge lclk); #1; l_set = 0;
    @(posedge fclk); #1; f_set = 1; @(posedge fclk); #1; f_set = 0;
    wait_ticks(1);
    if (l_num !== 32'd1000 || f_num !== 32'd1000) begin errors++; $display("set_epoch: %0d %0d", l_num, f_num); end
    wait_ticks(2);
    if (l_num !== f_num) begin errors++; $display("epoch numbers differ %0d %0d", l_num, f_num); end
    // apply at target n = current + 2
    both_pend(l_num + 2, 32'hA1A1_0001);
    wait_ticks(1);
    if (l_act === 32'hA1A1_0001 || f_act === 32'hA1A1_0001) begin errors++; $display("applied too early"); end
    wait_ticks(1);
    if (l_act !== 32'hA1A1_0001 || f_act !== 32'hA1A1_0001) begin errors++; $display("not applied at target"); end
    if (t_fa - t_la < -8.2 || t_fa - t_la > 8.2) begin errors++; $display("apply skew %0.1f ns", t_fa - t_la); end
    // next tick
    both_pend(32'hFFFF_FFFF, 32'hA1A1_0002);
    wait_ticks(1);
    if (l_act !== 32'hA1A1_0002 || f_act !== 32'hA1A1_0002) begin errors++; $display("next-tick apply failed"); end
    // target in the past -> applied at the next tick, late_cnt
    both_pend(l_num - 5, 32'hA1A1_0003);
    wait_ticks(1);
    if (l_act !== 32'hA1A1_0003 || f_act !== 32'hA1A1_0003 || l_lc !== 16'd1 || f_lc !== 16'd1) begin errors++; $display("late apply failed (late %0d %0d)", l_lc, f_lc); end
    // overwritten pending set: only the last applies
    both_pend(l_num + 2, 32'hA1A1_0004);
    both_pend(l_num + 2, 32'hA1A1_0005);
    wait_ticks(2);
    if (l_act !== 32'hA1A1_0005 || f_act !== 32'hA1A1_0005 || l_ac !== 16'd4 || f_ac !== 16'd4) begin errors++; $display("overwrite failed (applies %0d %0d)", l_ac, f_ac); end
    // stale
    stale_lim = 8'd2;
    wait_ticks(2);
    if (l_stale || f_stale) begin errors++; $display("stale too early"); end
    wait_ticks(1);
    if (!l_stale || !f_stale) begin errors++; $display("not stale"); end
    // force_tick: next strobe
    begin
      int c0; c0 = nl;
      lt_cnt = -1;
      @(posedge lclk); #1; l_force = 1; @(posedge lclk); #1; l_force = 0;
      repeat (12) @(posedge lclk);
      if (nl != c0 + 1) begin errors++; $display("force_tick did not tick"); end
    end
    wait_ticks(2);
    if (errors == 0) $display("TEST PASSED tb_phy_epoch (%0d leader ticks, %0d follower ticks)", nl, nf);
    else $display("TEST FAILED tb_phy_epoch errors=%0d", errors);
    $finish;
  end
endmodule
