// ***************************************************************************
// phy_tx_axis_top -- TX-only build wrapper: packets from the PS (axi_dmac, memory -> AXI-stream, 64-bit)
//   -> phy_tx_top (OFDM PHY) -> IQ to the AD9361 DAC interface (l_clk domain, pulled by dac_valid),
//   plus an AXI4-Lite register block (control + logging).
// Plain Verilog on purpose (block-design module reference); the SystemVerilog PHY blocks are in the same project.
//
// Stream format (one DMA transfer per packet, tlast on the last beat; beats are 64 bit, bytes LSB first):
//   beat 0 : {32'h4F465458 ('OFTX'), 16'h0000, nbytes[15:0]}   (header, consumed here)
//   beat 1..: payload, nbytes bytes (the remainder of the last beat is ignored); the PHY zero-pads it to a multiple of 550
//             bytes (one OFDM symbol). Packets with a bad header are dropped (counted).
// Inter-packet gap: the next packet is accepted only when the PHY is idle and `gap_samples` DAC samples have elapsed since
//   it became idle (the receiver handles one packet at a time and needs ~12000 samples to re-arm).
// Registers (base 0x7C440000 in the BD, generic part in rtl/common/phy_regs_axil.v):
//   cfg 0x10 GAIN (Q2.14, 16384 = 1.0)   0x14 GAP_SAMPLES   0x18 ENABLE (bit0, packets are only accepted when 1) + MODE (bit1: 0 = MAX RANGE
//   QPSK + LDPC 1/2, 1 = MAX RATE 16-QAM + LDPC 5/6; sampled with the first byte of a packet, change it only between packets)
//   status snapshot words (write SNAP 0x08, poll bit0, read 0x80 + 4*i):
//     0 {pkt_done, pkt_accepted}   1 {trunc, overflow}   2 {bad_header, underflow}   3 dac samples   4 clk count
//     5 busy clocks   6 active (non-idle) dac samples   7 {peak|q|, peak|i|} of the output   8 dma beats   9 dma stall clocks
//     10 last nbytes   11 {.., state, busy}   12 gap counter   13 gain   14 last iq {q, i}   15 bad-header dropped beats
//     31 {BF, MODE, CODED}
//
// BF = 1 (beamforming, TestTask006): two DAC channels, per-channel weights + output NCO, EPOCH time base and the JP5 bus.
//   Header flags (beat 0 bits [31:16]): bit15 EXT (0 = legacy: channel mask from cfg2[3:2], no flags), bits[1:0] channel mask,
//     bit2 SOUND (sounding frame: unit weight, only the tick-phase delay), bit3 TIMED: beat 1 = {32'd0, launch} is part of the header
//     and the packet starts at the strobe with index `launch` after an EPOCH tick (index 0 = first strobe after the tick; a packet that
//     is not ready at that strobe waits for the next epoch, counted in launch_miss).
//   cfg 2 0x18 [0] ENABLE [1] MODE [3:2] default channel mask (reset 01) [4] tick-phase compensation (reset 1)
//   cfg 3 0x1C [1:0] role (0 off, 1 leader, 2 follower) [2] safe mute (outputs 0 while stale) [15:8] stale limit (ticks, 0 = off)
//              [23:16] bus SCLK half period (clocks, reset 12) [29:24] bus frame length (bytes)
//   cfg 4..7 / 8..11 (0x20 / 0x30) channel 0 / 1: {phase, amp} {ctrl (bit0 weights, bit1 NCO), tau} rho inc   (python/bf_ref.py units)
//   cfg 12 0x40 epoch period (strobes, reset 307200 = 10 ms)   13 0x44 commit target epoch (0xFFFFFFFF = next tick)   14 0x48 set-epoch value
//   cfg 28..39 0x400..0x42C bus transmit buffer (byte i at word i/4, bits 8*(i%4))
//   CTRL pulses: bit2 commit (cfg channel parameters -> pending set, applied at the target tick), bit3 bus send, bit4 set epoch (cfg 14
//     taken at the next tick), bit5 force tick (leader). A follower takes PARAMS frames from the bus as pending sets, SET_EPOCH frames
//     as the epoch number for the next tick.
//   Weights per packet: channel not in the mask -> mute; SOUND or ctrl.weights = 0 -> unit weight with tau = tick_adj (bypass if 0);
//     else amp, phase, tau = tau_now (phy_tau_track: tau on apply + rho per strobe) + tick_adj. tick_adj = tick_phase * 256 / P.
//   Output: phy_nco_mixer (ctrl.NCO) or a matched 7-clock delay, held for the DAC (2 strobes later than BF = 0 at 4 clocks per strobe).
//   status 16 epoch   17/18 ts_tick lo/hi   19 since   20 {late, applies}   21 {stale, pend, p2, 0, log2[3:0], 16'd0, tick_phase}
//     22 timed launches   23 launch misses   24 {crc_err, rx_ok}   25 {resp_bad, resp_ok}   26/27 sample count at the last go lo/hi
//     28 strobe index of the last go   29 {.., tx_busy}   32..43 last bus frame (follower)   44..48 last response (leader)
//     49..56 active parameters (ch0 w0..w3, ch1 w0..w3)   57/58 sample count lo/hi
// ***************************************************************************
`timescale 1ns/100ps

module phy_tx_axis_top #(
  parameter [15:0] GAIN    = 16'd16384,
  parameter [31:0] GAP     = 32'd16384,
  parameter        ENABLE  = 1'b1,
  parameter        MODE    = 1'b1,            // reset value of the PHY mode (1 = MAX RATE, 0 = MAX RANGE)
  parameter        CODED   = 1'b1,            // LDPC R=5/6 (450 payload bytes per OFDM symbol, Zynq-7020 design); 0 = uncoded (550)
  parameter        BF      = 1'b0             // beamforming: two DAC channels, weights, NCO, EPOCH, JP5 bus
) (
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF PHY_STREAM" *)   /* keeps l_clk away from the AXI-Lite port (ad_cpu_interconnect picks the S_AXI clock by ASSOCIATED_BUSIF) */
  input         clk,           // AD9361 l_clk
  (* X_INTERFACE_INFO = "xilinx.com:signal:data:1.0 rst DATA" *)    /* plain signal: keeps Vivado from auto-associating it with s_axi_aclk */
  input         rst,
  input         s_axis_valid,
  output        s_axis_ready,
  input  [63:0] s_axis_data,
  input         s_axis_last,
  input         dac_valid,     // core requests one sample
  output [15:0] dac_data_i,
  output [15:0] dac_data_q,
  output        dac_dunf,
  output [15:0] dac_data_i1,   // BF: second DAC channel (0 otherwise)
  output [15:0] dac_data_q1,
  // BF: JP5 pins (t = 1 -> Hi-Z; all Hi-Z while role = 0)
  input         ep_i,   output ep_o,   output ep_t,
  input         sclk_i, output sclk_o, output sclk_t,
  input         mosi_i, output mosi_o, output mosi_t,
  input         up_i,   output up_o,   output up_t,

  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
  input         s_axi_aclk,
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input         s_axi_aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)  input  [11:0] s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input         s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output        s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)   input  [31:0] s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)   input  [3:0]  s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)  input         s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)  output        s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)   output [1:0]  s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)  output        s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)  input         s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)  input  [11:0] s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input         s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output        s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)   output [31:0] s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)   output [1:0]  s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)  output        s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)  input         s_axi_rready
);
  localparam NCFG = BF ? 40 : 3;
  localparam NST  = BF ? 64 : 32;
  localparam [1279:0] BF_INIT = {{(32*25){1'b0}}, 32'd0, 32'hFFFFFFFF, 32'd307200, {(32*8){1'b0}}, {8'd0, 8'd12, 8'd0, 8'd0},
                                 {27'd0, 1'b1, 2'b01, MODE, ENABLE}, GAP, 16'd0, GAIN};
  localparam [32*NCFG-1:0] CFG_INIT_ALL = BF ? BF_INIT : {{30'd0, MODE, ENABLE}, GAP, 16'd0, GAIN};
  localparam [31:0] MAGIC = 32'h4F465458;
  localparam [1:0] S_HDR = 2'd0, S_BODY = 2'd1, S_DRAIN = 2'd2, S_HDR2 = 2'd3;

  wire [32*NCFG-1:0] cfg;
  wire               soft_rst, clr;
  wire [5:0]         pulse;
  wire [32*NST-1:0]  stat;
  wire [15:0]        gain_w   = cfg[15:0];
  wire [31:0]        gap_w    = cfg[63:32];
  wire               enable_w = cfg[64];
  wire               mode_w   = cfg[65];

  reg rst_r = 1'b1;                       // local reset copy (AD9361 reset has a large fanout) + PS soft reset
  always @(posedge clk) rst_r <= rst | soft_rst;

  // ---------------------------------------------------------------- packet framing + 64 -> 8 bit serialiser
  reg [1:0]  st = S_HDR;
  reg [63:0] word = 64'd0;
  reg        got_last = 1'b0;
  reg [3:0]  left = 4'd0;                // bytes left in `word`
  reg [15:0] rem = 16'd0;                // payload bytes still to be sent
  reg [31:0] gap_cnt = 32'd0;
  wire       phy_ready, phy_busy;
  wire       gap_ok = (gap_cnt >= gap_w);

  reg [15:0] n_acc = 0, n_bad = 0, n_unf = 0, n_ovf = 0, n_trunc = 0, n_done = 0, last_nb = 0;
  reg [31:0] n_beat = 0, n_stall = 0, n_samp = 0, n_clk = 0, n_busy = 0, n_act = 0, n_dropped = 0;
  reg [15:0] pk_i = 0, pk_q = 0;
  reg [31:0] last_iq = 0;

  wire in_hdr   = (st == S_HDR);
  assign s_axis_ready = (in_hdr && gap_ok && enable_w && !phy_busy) || (st == S_BODY && left == 4'd0 && rem != 16'd0) || (st == S_DRAIN)
                        || (st == S_HDR2);
  wire acc = s_axis_valid && s_axis_ready;

  wire byte_valid = (st == S_BODY) && (left != 4'd0) && (rem != 16'd0);
  wire byte_take  = byte_valid && phy_ready;
  wire last_byte  = (rem == 16'd1) || (got_last && left == 4'd1);

  wire hdr_ok = (s_axis_data[63:32] == MAGIC) && (s_axis_data[15:0] != 16'd0) && !s_axis_last;
  // BF packet flags (latched with the header; the next header is only taken when the PHY is idle -> stable for the packet)
  wire       f_ext = BF && s_axis_data[31];
  reg  [1:0] f_mask = 2'b01;
  reg        f_sound = 1'b0, f_timed = 1'b0, tp_pend = 1'b0;
  reg [31:0] f_launch = 32'd0;
  wire       go_fire;

  always @(posedge clk) begin
    if (rst_r) begin
      st <= S_HDR; left <= 4'd0; word <= 64'd0; got_last <= 1'b0; rem <= 16'd0;
    end else begin
      if (acc) begin
        case (st)
          S_HDR: begin
            if (hdr_ok) begin
              st <= (f_ext && s_axis_data[19]) ? S_HDR2 : S_BODY; rem <= s_axis_data[15:0]; left <= 4'd0; got_last <= 1'b0;
              f_mask  <= f_ext ? s_axis_data[17:16] : cfg[67:66];
              f_sound <= f_ext & s_axis_data[18];
              f_timed <= f_ext & s_axis_data[19];
            end
            else if (!s_axis_last) st <= S_DRAIN;
          end
          S_HDR2: begin f_launch <= s_axis_data[31:0]; st <= s_axis_last ? S_HDR : S_BODY; if (s_axis_last) rem <= 16'd0; end
          S_BODY: begin word <= s_axis_data; left <= 4'd8; got_last <= s_axis_last; end
          S_DRAIN: if (s_axis_last) st <= S_HDR;
          default: st <= S_HDR;
        endcase
      end else if (byte_take) begin
        word <= {8'd0, word[63:8]};
        left <= left - 4'd1;
        rem  <= rem - 16'd1;
        if (last_byte) begin left <= 4'd0; rem <= 16'd0; st <= got_last ? S_HDR : S_DRAIN; end
      end
    end
  end

  always @(posedge clk) begin                                   // a timed packet is waiting for its launch strobe
    if (rst_r) tp_pend <= 1'b0;
    else if (acc && in_hdr && hdr_ok) tp_pend <= f_ext & s_axis_data[19];
    else if (go_fire) tp_pend <= 1'b0;
  end

  wire        pkt_done;
  wire [15:0] iq_re, iq_im, iq1_re, iq1_im;
  wire        iq_valid, underflow, overflow, trunc;
  wire        go_en;
  wire [3:0]  w_mode;
  wire [31:0] w_amp, w_phase;
  wire [33:0] w_tau;

  phy_tx_top #(.CODED(CODED), .BF(BF)) u_phy (
    .clk(clk), .rst(rst_r), .gain(gain_w), .cfg_mode(mode_w),
    .s_valid(byte_valid), .s_ready(phy_ready), .s_data(word[7:0]), .s_last(last_byte),
    .iq_pull(dac_valid), .iq_re(iq_re), .iq_im(iq_im), .iq_valid(iq_valid),
    .underflow(underflow), .overflow(overflow), .pkt_trunc(trunc), .pkt_done(pkt_done),
    .busy(phy_busy),
    .go_en(go_en), .go_fire(go_fire), .w_mode(w_mode), .w_amp(w_amp), .w_phase(w_phase), .w_tau(w_tau),
    .iq1_re(iq1_re), .iq1_im(iq1_im)
  );
  assign dac_dunf = underflow;

  wire [32*14-1:0] bf_stat_lo;                    // status words 16..29 (BF)
  wire [32*27-1:0] bf_stat;                       // status words 32..58 (BF)
  generate if (!BF) begin : g_nobf
    assign dac_data_i = iq_re;
    assign dac_data_q = iq_im;
    assign dac_data_i1 = 16'd0; assign dac_data_q1 = 16'd0;
    assign go_en = 1'b1; assign w_mode = 4'd0; assign w_amp = 32'd0; assign w_phase = 32'd0; assign w_tau = 34'd0;
    assign ep_o = 1'b0; assign ep_t = 1'b1; assign sclk_o = 1'b0; assign sclk_t = 1'b1;
    assign mosi_o = 1'b0; assign mosi_t = 1'b1; assign up_o = 1'b0; assign up_t = 1'b1;
    assign bf_stat_lo = {32*14{1'b0}}; assign bf_stat = {32*27{1'b0}};
  end else begin : g_bf
    // ------------------------------------------------------------ configuration
    wire [1:0]   role      = cfg[97:96];
    wire         safe_mute = cfg[98];
    wire [7:0]   stale_lim = cfg[111:104];
    wire [7:0]   bus_div   = cfg[119:112];
    wire [5:0]   bus_len   = cfg[125:120];
    wire         tpc_en    = cfg[68];
    wire [31:0]  period    = cfg[32*12 +: 32];
    wire [31:0]  commit_tg = cfg[32*13 +: 32];
    wire [31:0]  set_val_r = cfg[32*14 +: 32];
    wire [255:0] cfg_par   = cfg[32*4 +: 256];      // ch0 w0..w3, ch1 w0..w3
    wire [383:0] txbuf     = cfg[32*28 +: 384];

    // ------------------------------------------------------------ JP5 bus
    wire         rx_ok, rx_bad, resp_ok, resp_bad, tx_busy;
    wire [383:0] rx_last, rx_work;
    wire [151:0] resp_last;
    wire [15:0]  rx_crc_err, bus_status;
    wire [31:0]  epoch_num;
    wire [63:0]  ts_tick;
    phy_syncbus u_bus (
      .clk(clk), .rst(rst_r), .role(role), .div(bus_div),
      .tx_start(pulse[1]), .tx_len(bus_len), .tx_buf(txbuf), .tx_busy(tx_busy), .resp_ok(resp_ok), .resp_bad(resp_bad), .resp_last(resp_last),
      .rx_ok(rx_ok), .rx_bad(rx_bad), .rx_last(rx_last), .rx_work(rx_work), .rx_crc_err(rx_crc_err),
      .resp_status(bus_status), .resp_epoch(epoch_num), .resp_ts(ts_tick),
      .sclk_i(sclk_i), .mosi_i(mosi_i), .up_i(up_i), .sclk_o(sclk_o), .mosi_o(mosi_o), .up_o(up_o),
      .sclk_t(sclk_t), .mosi_t(mosi_t), .up_t(up_t)
    );
    // follower: PARAMS (type 1, len 36) -> pending set, SET_EPOCH (type 2, len 4) -> epoch number at the next tick.
    // rx_work bytes: 0 type, 1 seq, 2 len, 3..6 target / epoch, 7..22 channel 0 block, 23..38 channel 1 block; a 16-byte block
    // (LE amp, phase, tau, ctrl, rho, inc) has the same bit layout as the parameter words {phase, amp} {ctrl, tau} rho inc.
    wire bus_params = rx_ok && rx_work[7:0] == 8'h01 && rx_work[23:16] == 8'd36;
    wire bus_setep  = rx_ok && rx_work[7:0] == 8'h02 && rx_work[23:16] == 8'd4;

    // ------------------------------------------------------------ EPOCH, pending / active parameters
    wire         tick, apply, pend_valid, stale, strobe_p2, ep_drv;
    wire [63:0]  sample_cnt;
    wire [31:0]  since;
    wire [7:0]   tick_phase;
    wire [3:0]   strobe_log2;
    wire [255:0] active;
    wire [15:0]  apply_cnt, late_cnt;
    wire         pend_we = pulse[0] | bus_params;
    wire [31:0]  pend_tg = pulse[0] ? commit_tg : rx_work[24 +: 32];
    wire [255:0] pend_d  = pulse[0] ? cfg_par : rx_work[56 +: 256];
    phy_epoch #(.PW(256)) u_ep (
      .clk(clk), .rst(rst_r), .strobe(dac_valid), .role(role), .period(period), .force_tick(pulse[3]),
      .ep_pin_i(ep_i), .ep_pin_o(ep_drv), .set_epoch(pulse[2] | bus_setep), .set_epoch_val(pulse[2] ? set_val_r : rx_work[24 +: 32]),
      .pend_we(pend_we), .pend_target(pend_tg), .pend_data(pend_d), .stale_lim(stale_lim),
      .tick(tick), .epoch_num(epoch_num), .sample_cnt(sample_cnt), .ts_tick(ts_tick), .since(since), .tick_phase(tick_phase),
      .strobe_log2(strobe_log2), .strobe_p2(strobe_p2), .active(active), .apply(apply), .pend_valid(pend_valid),
      .apply_cnt(apply_cnt), .late_cnt(late_cnt), .stale(stale)
    );
    assign ep_o = ep_drv;
    assign ep_t = (role != 2'd1);
    assign bus_status = {11'd0, stale, pend_valid, (late_cnt != 16'd0), (apply_cnt != 16'd0), rx_ok};

    // ------------------------------------------------------------ launch timing
    wire [31:0] idx_now    = tick ? 32'd0 : since + 32'd1;     // index of the strobe in this cycle
    wire        launch_hit = dac_valid && (idx_now == f_launch);
    assign go_en = !f_timed || launch_hit;
    wire [8:0]  tick_adj = (tpc_en && strobe_p2) ? ({1'b0, tick_phase} << (4'd8 - strobe_log2)) : 9'd0;

    // ------------------------------------------------------------ per channel: tau tracker, weights, NCO, output register
    wire [31:0] o_iq [0:1];
    genvar c;
    for (c = 0; c < 2; c = c + 1) begin : g_ch
      wire [15:0] amp   = active[128*c +: 16];
      wire [15:0] phase = active[128*c + 16 +: 16];
      wire [15:0] tau   = active[128*c + 32 +: 16];
      wire [15:0] ctrl  = active[128*c + 48 +: 16];
      wire [31:0] rho   = active[128*c + 64 +: 32];
      wire [31:0] inc   = active[128*c + 96 +: 32];
      wire [15:0] tau_now;
      phy_tau_track u_tt (.clk(clk), .rst(rst_r), .strobe(dac_valid), .set(apply), .tau_set(tau), .rho(rho), .tau_now(tau_now));
      wire        unit  = f_sound || !ctrl[0];
      assign w_mode[2*c +: 2]    = !f_mask[c] ? 2'd2 : (unit && tick_adj == 9'd0) ? 2'd0 : 2'd1;
      assign w_amp[16*c +: 16]   = unit ? 16'd32767 : amp;
      assign w_phase[16*c +: 16] = unit ? 16'd0 : phase;
      assign w_tau[17*c +: 17]   = unit ? {8'd0, tick_adj} : ({tau_now[15], tau_now} + {8'd0, tick_adj});
      // output NCO (continuous phase, advanced by every DAC strobe) or a matched delay; the result is held for the DAC
      wire [15:0] xi = c ? iq1_re : iq_re;
      wire [15:0] xq = c ? iq1_im : iq_im;
      wire        nv;
      wire [15:0] ni, nq;
      phy_nco_mixer u_nco (.clk(clk), .rst(rst_r), .inc(inc), .ph_clr(1'b0), .in_valid(dac_valid), .in_i(xi), .in_q(xq),
                           .out_valid(nv), .out_i(ni), .out_q(nq));
      reg [31:0] dl [0:6];
      reg [31:0] hold = 32'd0;
      integer k;
      always @(posedge clk) begin
        dl[0] <= {xi, xq};
        for (k = 1; k < 7; k = k + 1) dl[k] <= dl[k-1];
        if (nv) hold <= (safe_mute && stale) ? 32'd0 : ctrl[1] ? {ni, nq} : dl[6];
      end
      assign o_iq[c] = hold;
    end
    assign dac_data_i  = o_iq[0][31:16]; assign dac_data_q  = o_iq[0][15:0];
    assign dac_data_i1 = o_iq[1][31:16]; assign dac_data_q1 = o_iq[1][15:0];

    // ------------------------------------------------------------ statistics
    reg [15:0] n_rxok = 0, n_rok = 0, n_rbad = 0;
    reg [31:0] n_launch = 0, n_miss = 0, go_idx = 0;
    reg [63:0] go_ts = 0;
    always @(posedge clk) begin
      if (rst_r || clr) begin n_rxok <= 0; n_rok <= 0; n_rbad <= 0; n_launch <= 0; n_miss <= 0; end
      else begin
        if (rx_ok) n_rxok <= n_rxok + 1'b1;
        if (resp_ok) n_rok <= n_rok + 1'b1;
        if (resp_bad) n_rbad <= n_rbad + 1'b1;
        if (go_fire && f_timed) n_launch <= n_launch + 1'b1;
        if (launch_hit && tp_pend && !go_fire) n_miss <= n_miss + 1'b1;
      end
      if (go_fire) begin go_ts <= sample_cnt; go_idx <= idx_now; end
    end
    assign bf_stat_lo = {{31'd0, tx_busy}, go_idx, go_ts[63:32], go_ts[31:0], {n_rbad, n_rok}, {rx_crc_err, n_rxok}, n_miss, n_launch,
                         {stale, pend_valid, strobe_p2, 1'b0, strobe_log2, 16'd0, tick_phase}, {late_cnt, apply_cnt}, since,
                         ts_tick[63:32], ts_tick[31:0], epoch_num};
    assign bf_stat = {sample_cnt[63:32], sample_cnt[31:0], active, 8'd0, resp_last, rx_last};
  end endgenerate

  // ---------------------------------------------------------------- gap counter + logging counters (cleared by `clr`)
  // the output samples come straight from a BRAM: register them before the logging logic (timing)
  reg [15:0] re_q = 0, im_q = 0; reg act_q = 1'b0;
  always @(posedge clk) begin re_q <= iq_re; im_q <= iq_im; act_q <= dac_valid && iq_valid; end
  wire [15:0] ai = re_q[15] ? (~re_q + 16'd1) : re_q;
  wire [15:0] aq = im_q[15] ? (~im_q + 16'd1) : im_q;
  wire        hdr_beat = acc && in_hdr;
  always @(posedge clk) begin
    if (rst_r) gap_cnt <= 32'd0;
    else if (phy_busy || (st != S_HDR)) gap_cnt <= 32'd0;
    else if (dac_valid && !gap_ok) gap_cnt <= gap_cnt + 32'd1;

    if (rst_r || clr) begin
      n_acc <= 0; n_bad <= 0; n_unf <= 0; n_ovf <= 0; n_trunc <= 0; n_done <= 0; n_beat <= 0; n_stall <= 0;
      n_samp <= 0; n_clk <= 0; n_busy <= 0; n_act <= 0; n_dropped <= 0; pk_i <= 0; pk_q <= 0;
    end else begin
      n_clk <= n_clk + 1'b1;
      if (phy_busy) n_busy <= n_busy + 1'b1;
      if (dac_valid) n_samp <= n_samp + 1'b1;
      if (act_q) begin
        n_act <= n_act + 1'b1;
        if (ai > pk_i) pk_i <= ai;
        if (aq > pk_q) pk_q <= aq;
        last_iq <= {im_q, re_q};
      end
      if (acc) n_beat <= n_beat + 1'b1;
      if (s_axis_valid && !s_axis_ready) n_stall <= n_stall + 1'b1;
      if (hdr_beat && hdr_ok) begin n_acc <= n_acc + 1'b1; last_nb <= s_axis_data[15:0]; end
      if (hdr_beat && !hdr_ok) n_bad <= n_bad + 1'b1;
      if (acc && st == S_DRAIN) n_dropped <= n_dropped + 1'b1;
      if (underflow) n_unf <= n_unf + 1'b1;
      if (overflow) n_ovf <= n_ovf + 1'b1;
      if (trunc) n_trunc <= n_trunc + 1'b1;
      if (pkt_done) n_done <= n_done + 1'b1;
    end
  end

  wire [31:0] sw [0:NST-1];
  assign sw[0]  = {n_done, n_acc};
  assign sw[1]  = {n_trunc, n_ovf};
  assign sw[2]  = {n_bad, n_unf};
  assign sw[3]  = n_samp;
  assign sw[4]  = n_clk;
  assign sw[5]  = n_busy;
  assign sw[6]  = n_act;
  assign sw[7]  = {pk_q, pk_i};
  assign sw[8]  = n_beat;
  assign sw[9]  = n_stall;
  assign sw[10] = {16'd0, last_nb};
  assign sw[11] = {28'd0, st, 1'b0, phy_busy};
  assign sw[12] = gap_cnt;
  assign sw[13] = {16'd0, gain_w};
  assign sw[14] = last_iq;
  assign sw[15] = n_dropped;
  genvar gi;
  generate for (gi = 16; gi < 30; gi = gi + 1) begin : g_lo assign sw[gi] = bf_stat_lo[32*(gi-16) +: 32]; end endgenerate
  assign sw[30] = 32'd0;
  assign sw[31] = {29'd0, BF, mode_w, CODED};
  generate for (gi = 32; gi < NST; gi = gi + 1) begin : g_hi assign sw[gi] = (gi < 59) ? bf_stat[32*(gi-32) +: 32] : 32'd0; end endgenerate
  generate for (gi = 0; gi < NST; gi = gi + 1) begin : g_stat assign stat[32*gi +: 32] = sw[gi]; end endgenerate

  phy_regs_axil #(
    .ID(32'h4F465458), .NCFG(NCFG), .NST(NST),
    .CFG_INIT(CFG_INIT_ALL)
  ) u_regs (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .phy_clk(clk), .cfg_o(cfg), .soft_rst_o(soft_rst), .clr_o(clr), .pulse_o(pulse), .stat_i(stat)
  );
endmodule
