// Module : phy_epoch   common time base of the beamforming boards (TestTask006): EPOCH pulse, sample counter, atomic parameter apply.
//   role 1 (leader): counts DAC strobes, every `period` strobes drives ep_pin_o high for EPW clocks (force_tick restarts the period
//     at the next strobe). The leader's own pin register goes through the same 2-FF synchroniser as the follower's input, so both
//     boards see the tick with the same synchroniser delay (the follower additionally the wire / IO delay, ~1 clock).
//   role 2 (follower): tick = rising edge of the synchronised ep_pin_i.   role 0: no ticks.
//   On a tick: epoch_num <- set value (if set_epoch was requested) else epoch_num + 1; ts_tick <- sample_cnt; since <- -1
//     (the first strobe after the tick, or a strobe in the tick cycle, has index 0: `since` holds the index of the last strobe).
//     tick_phase = clocks from the tick to that first strobe (0 if they coincide); with P = 2^strobe_log2 clocks per strobe the
//     frame start is late by tick_phase / P samples (compensated in the weights by the caller).
//   Parameters: pend_we stores pend_data / pend_target (a new write replaces a pending set). At a tick with new number n the pending
//     set becomes active (apply pulse) if target == 0xFFFFFFFF, target == n, or target is in the past (late_cnt++).
//   stale = more than stale_lim ticks since the last apply (stale_lim = 0: never stale).
// Latency: tick = 3 clocks after the leader's pin register rises. Control logic; verified by tb_phy_epoch (two boards, two clocks).
module phy_epoch #(
  parameter int PW  = 32,         // parameter vector width
  parameter int EPW = 16          // EPOCH pulse width (clocks)
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          strobe,
  input  logic [1:0]    role,
  input  logic [31:0]   period,
  input  logic          force_tick,
  input  logic          ep_pin_i,
  output logic          ep_pin_o,
  input  logic          set_epoch,
  input  logic [31:0]   set_epoch_val,
  input  logic          pend_we,
  input  logic [31:0]   pend_target,
  input  logic [PW-1:0] pend_data,
  input  logic [7:0]    stale_lim,
  output logic          tick,
  output logic [31:0]   epoch_num,
  output logic [63:0]   sample_cnt,
  output logic [63:0]   ts_tick,
  output logic [31:0]   since,
  output logic [7:0]    tick_phase,
  output logic [3:0]    strobe_log2,
  output logic          strobe_p2,      // measured strobe period is a power of two (tick_phase compensation valid)
  output logic [PW-1:0] active,
  output logic          apply,
  output logic          pend_valid,
  output logic [15:0]   apply_cnt,
  output logic [15:0]   late_cnt,
  output logic          stale
);
  // ---------------------------------------------------------------- leader period counter / pin
  logic [31:0] pcnt;
  logic [7:0]  pw_cnt;
  always_ff @(posedge clk) begin
    if (rst || role != 2'd1) begin pcnt <= '0; ep_pin_o <= 1'b0; pw_cnt <= '0; end
    else begin
      if (force_tick) pcnt <= period - 1;
      else if (strobe) pcnt <= (pcnt >= period - 1) ? '0 : pcnt + 1'b1;
      if (strobe && !force_tick && pcnt >= period - 1) begin ep_pin_o <= 1'b1; pw_cnt <= 8'(EPW - 1); end
      else if (pw_cnt != 0) pw_cnt <= pw_cnt - 1'b1;
      else ep_pin_o <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- synchroniser + edge -> tick
  (* ASYNC_REG = "TRUE" *) logic s1, s2;
  logic s3;
  wire  src = (role == 2'd1) ? ep_pin_o : (role == 2'd2) ? ep_pin_i : 1'b0;
  always_ff @(posedge clk) begin
    s1 <= src; s2 <= s1; s3 <= s2;
    if (rst) begin s1 <= 1'b0; s2 <= 1'b0; s3 <= 1'b0; end
  end
  assign tick = s2 & ~s3;

  // ---------------------------------------------------------------- counters, tick phase, strobe period
  logic       set_pend;
  logic [31:0] set_val;
  logic [7:0] tp_cnt; logic tp_run;
  logic [7:0] sp_cnt, sp_last;
  wire  [31:0] new_num = set_pend ? set_val : epoch_num + 1'b1;
  always_ff @(posedge clk) begin
    if (rst) begin
      sample_cnt <= '0; ts_tick <= '0; since <= '1; epoch_num <= '0; set_pend <= 1'b0; set_val <= '0;
      tick_phase <= '0; tp_cnt <= '0; tp_run <= 1'b0; sp_cnt <= '0; sp_last <= '0;
    end else begin
      if (strobe) sample_cnt <= sample_cnt + 1'b1;
      if (set_epoch) begin set_pend <= 1'b1; set_val <= set_epoch_val; end
      if (tick) begin
        epoch_num <= new_num;
        if (!set_epoch) set_pend <= 1'b0;
        ts_tick <= sample_cnt;
        since   <= strobe ? 32'd0 : '1;
        tp_cnt  <= '0;
        tp_run  <= ~strobe;
        if (strobe) tick_phase <= '0;
      end else begin
        if (strobe) since <= since + 1'b1;
        if (tp_run) begin
          tp_cnt <= tp_cnt + 1'b1;
          if (strobe) begin tick_phase <= tp_cnt + 1'b1; tp_run <= 1'b0; end
        end
      end
      // strobe period (clocks between strobes)
      if (strobe) begin sp_last <= sp_cnt + 1'b1; sp_cnt <= '0; end
      else if (sp_cnt != 8'hFF) sp_cnt <= sp_cnt + 1'b1;
    end
  end
  always_comb begin
    strobe_p2 = 1'b1;
    case (sp_last)
      8'd1: strobe_log2 = 4'd0;
      8'd2: strobe_log2 = 4'd1;
      8'd4: strobe_log2 = 4'd2;
      8'd8: strobe_log2 = 4'd3;
      default: begin strobe_log2 = 4'd2; strobe_p2 = 1'b0; end
    endcase
  end

  // ---------------------------------------------------------------- pending -> active
  logic [31:0] pend_tgt;
  logic [PW-1:0] pend_d;
  logic [7:0]  since_apply;
  wire  [31:0] dlt = new_num - pend_tgt;
  wire         hit  = (pend_tgt == 32'hFFFFFFFF) || (pend_tgt == new_num);
  wire         late = !hit && (dlt != 0) && !dlt[31];
  always_ff @(posedge clk) begin
    apply <= 1'b0;
    if (rst) begin
      pend_valid <= 1'b0; active <= '0; apply_cnt <= '0; late_cnt <= '0; since_apply <= '0; pend_tgt <= '0; pend_d <= '0;
    end else begin
      if (tick) since_apply <= (since_apply == 8'hFF) ? since_apply : since_apply + 1'b1;
      if (tick && pend_valid && (hit || late)) begin
        active <= pend_d; apply <= 1'b1; pend_valid <= 1'b0; apply_cnt <= apply_cnt + 1'b1; since_apply <= '0;
        if (late) late_cnt <= late_cnt + 1'b1;
      end
      if (pend_we) begin pend_valid <= 1'b1; pend_tgt <= pend_target; pend_d <= pend_data; end
    end
  end
  assign stale = (stale_lim != 0) && (since_apply > stale_lim);
endmodule
