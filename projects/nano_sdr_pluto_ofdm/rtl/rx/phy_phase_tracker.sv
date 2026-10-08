// Module : phy_phase_tracker   common-phase-error (CPE) correction per OFDM symbol from the pilots.
//   Input : equalised active-bin stream (valid-only, 1200 bins/symbol, in_first = bin 0, in_last = bin 1199); pilots sit at
//           index % PILOT_SPACING == PILOT_OFFSET with the TX pseudo-random sign (x^15+x^14+1 LFSR, PILOT_SEED, per symbol).
//   SLOPE = 1: additionally M = sum_p f_p X_p sigma_p (f_p = frequency index of the pilot, -594..595), s = Im(M e^{-j theta}) / (A sum f^2),
//   every bin (frequency index f) is rotated by exp(-j(theta + s f)) with a 32 bit phase accumulator and phy_sincos (golden
//   python/rx_fixed_ref.py::cpe_sfo_track).
//   Step  : acc = sum_p X_p * sigma_p ; theta = angle(acc) (phy_cordic, acc normalised to 17 bit) ; every data bin is rotated by
//           exp(-j*theta) with cos/sin from phy_sincos (12-bit phase) and phy_complex_mult (round half up, saturate 16 bit).
//   The whole symbol is buffered (1200 x 32 bit RAM); the data bins (pilots removed, 1100) are streamed out after the angle is
//   known. A new symbol must not start before the previous read-out finished (overrun flag latches otherwise).
// Latency: in_last -> first output ~ 45 cycles; output rate 1 sample/cycle (1100 samples, valid-only).
// Pilots are rotated too (same multiplier, masked from the output stream); l1_val = sum over the 100 pilots of
//   |re - sigma*PILOT_AMP| + |im| (golden cpe_track_l1), valid ~10 cycles after the last read-out bin.
// DSP: 4 (rotation).   Golden: python/rx_fixed_ref.py::cpe_track (bit-exact, data bins only; angle_o = golden `ang`).
module phy_phase_tracker
  import phy_pkg::*;
#(
  parameter bit SLOPE = 1'b0,                // 1: fit the phase slope over frequency (sampling clock offset) and rotate every bin by theta + s*f
  parameter int SFO_KB = 4849                // Q20 constant 2^32 / (2 pi A sum f^2) * 2^20 (python/rx_fixed_ref.py::SFO_KB_Q16)
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im,
  output logic [31:0]            angle_o,
  output logic                   angle_valid,
  output logic                   busy,
  output logic                   overrun,
  output logic                   l1_valid,       // one pulse per symbol: sum |pilot_rotated - sigma*A| (I and Q) = EVM proxy
  output logic [23:0]            l1_val,
  output logic [31:0]            slope_o,        // phase slope per bin (2^32 = 2 pi), valid with slope_valid (SLOPE = 1)
  output logic                   slope_valid
);
  localparam int NA = NUM_ACTIVE_SC;
  localparam int XW = 18;
  localparam logic signed [63:0] KB64 = 64'(SFO_KB);

  // ---------------------------------------------------------------- write side: buffer + pilot accumulation
  logic [31:0] buf_ram [NA];
  logic [10:0] wcnt;
  logic [3:0]  pmod;
  logic [14:0] lfsr;
  logic signed [26:0] acc_r, acc_i;
  logic signed [39:0] macc_r, macc_i;                 // sum of f_p * z_p (slope mode)
  logic        last_seen;
  wire  [10:0] w_cur  = in_first ? 11'd0 : wcnt;
  wire  [3:0]  pm_cur = in_first ? 4'd0 : pmod;
  wire         is_pil = (pm_cur == 4'(PILOT_OFFSET));
  wire  [14:0] lf_cur = in_first ? PILOT_SEED : lfsr;
  wire         sig    = lf_cur[14] ^ lf_cur[13];
  wire signed [26:0] term_r = sig ? -27'(in_re) : 27'(in_re);
  wire signed [26:0] term_i = sig ? -27'(in_im) : 27'(in_im);
  wire signed [11:0] f_cur  = (w_cur < 11'd600) ? 12'(w_cur + 11'd1) : 12'(int'(w_cur) - 1200);

  always_ff @(posedge clk) begin
    if (in_valid) buf_ram[w_cur] <= {in_re, in_im};
  end

  always_ff @(posedge clk) begin
    last_seen <= 1'b0;
    if (rst) begin
      wcnt <= '0; pmod <= '0; lfsr <= PILOT_SEED; acc_r <= '0; acc_i <= '0; macc_r <= '0; macc_i <= '0;
    end else if (in_valid) begin
      wcnt <= w_cur + 1'b1;
      pmod <= (pm_cur == 4'(PILOT_SPACING - 1)) ? 4'd0 : pm_cur + 1'b1;
      if (is_pil) begin
        lfsr  <= {lf_cur[13:0], sig};
        acc_r <= (in_first ? 27'sd0 : acc_r) + term_r;
        acc_i <= (in_first ? 27'sd0 : acc_i) + term_i;
        macc_r <= (in_first ? 40'sd0 : macc_r) + 40'(term_r * f_cur);
        macc_i <= (in_first ? 40'sd0 : macc_i) + 40'(term_i * f_cur);
      end else if (in_first) begin
        lfsr <= PILOT_SEED; acc_r <= '0; acc_i <= '0; macc_r <= '0; macc_i <= '0;
      end
      last_seen <= in_last;
    end
  end

  // ---------------------------------------------------------------- control FSM: normalise -> CORDIC -> sin/cos -> read-out
  typedef enum logic [3:0] {S_IDLE, S_NORM, S_NORM2, S_START, S_WAIT, S_PHASE, S_SC, S_M1, S_M2, S_M3, S_M4, S_READ} st_t;
  st_t st;
  logic [4:0] shn, shn_q;
  logic signed [XW-1:0] cx, cy;
  logic         cstart, cbusy, cdone;
  logic [31:0]  cang;
  logic [11:0]  pidx;
  logic         sc_in_valid, sc_valid;
  logic signed [15:0] cs_c, cs_s, c_hold, s_hold;
  logic [10:0]  rcnt;
  logic [3:0]   rpm;
  logic [14:0]  rlf;
  logic signed [55:0] pm_c, pm_s;                    // slope mode: M * e^{-j theta} (imaginary part)
  logic signed [47:0] im_t;
  logic signed [63:0] sp_t;
  logic [31:0]  sbin, ph_acc;
  wire  [31:0]  s1200 = (sbin << 10) + (sbin << 7) + (sbin << 5) + (sbin << 4);

  wire [26:0] a_r = acc_r[26] ? 27'(-acc_r) : 27'(acc_r);
  wire [26:0] a_i = acc_i[26] ? 27'(-acc_i) : 27'(acc_i);
  wire [26:0] mm  = a_r | a_i;
  always_comb begin
    shn = '0;
    for (int b = 0; b < 27; b++) if (mm[b]) shn = (b + 1 > XW - 1) ? 5'(b + 1 - (XW - 1)) : 5'd0;
  end

  phy_cordic #(.XW(XW), .NITER(24)) u_cordic (
    .clk, .rst, .start(cstart), .x(cx), .y(cy), .busy(cbusy), .done(cdone), .angle(cang)
  );
  // sin/cos: one lookup for -theta (S_PHASE) and, in slope mode, one per bin during the read-out
  wire         sc_bin = (st == S_READ) && SLOPE;
  phy_sincos u_sc (.clk, .rst, .in_valid(sc_in_valid | sc_bin), .idx(sc_bin ? ph_acc[31:20] : pidx), .out_valid(sc_valid), .cos_o(cs_c), .sin_o(cs_s));

  assign busy = (st != S_IDLE);
  wire   r_is_pil = (rpm == 4'(PILOT_OFFSET));

  always_ff @(posedge clk) begin
    cstart <= 1'b0; sc_in_valid <= 1'b0; angle_valid <= 1'b0; slope_valid <= 1'b0;
    if (rst) begin
      sbin <= '0; ph_acc <= '0; slope_o <= '0; st <= S_IDLE; overrun <= 1'b0; rcnt <= '0; rpm <= '0; cx <= '0; cy <= '0; pidx <= '0; shn_q <= '0;
      c_hold <= '0; s_hold <= '0; angle_o <= '0; rlf <= PILOT_SEED;
    end else begin
      if (in_valid && in_first && st != S_IDLE) overrun <= 1'b1;
      case (st)
        S_IDLE:  if (last_seen) st <= S_NORM;
        S_NORM:  begin shn_q <= shn; st <= S_NORM2; end
        S_NORM2: begin cx <= XW'(acc_r >>> shn_q); cy <= XW'(acc_i >>> shn_q); st <= S_START; end
        S_START: begin cstart <= 1'b1; st <= S_WAIT; end
        S_WAIT:  if (cdone) begin angle_o <= cang; angle_valid <= 1'b1; st <= S_PHASE; end
        S_PHASE: begin pidx <= 12'((-angle_o) >> 20); sc_in_valid <= 1'b1; st <= S_SC; end
        S_SC:    if (sc_valid) begin
                   c_hold <= cs_c; s_hold <= cs_s; rcnt <= '0; rpm <= '0; rlf <= PILOT_SEED;
                   if (SLOPE) st <= S_M1; else begin sbin <= '0; ph_acc <= '0; st <= S_READ; end
                 end
        S_M1:    begin pm_c <= macc_i * c_hold; pm_s <= macc_r * s_hold; st <= S_M2; end
        S_M2:    begin im_t <= 48'((pm_c + pm_s) >>> 15); st <= S_M3; end
        S_M3:    begin sp_t <= 64'(im_t) * KB64; st <= S_M4; end
        S_M4:    begin
                   sbin <= sp_t[51:20]; slope_o <= sp_t[51:20]; slope_valid <= 1'b1;
                   ph_acc <= -angle_o - sp_t[51:20];
                   st <= S_READ;
                 end
        S_READ:  begin
          rcnt <= rcnt + 1'b1;
          ph_acc <= (rcnt == 11'(NA / 2 - 1)) ? ph_acc + s1200 : ph_acc - sbin;
          rpm  <= (rpm == 4'(PILOT_SPACING - 1)) ? 4'd0 : rpm + 1'b1;
          if (r_is_pil) rlf <= {rlf[13:0], rlf[14] ^ rlf[13]};
          if (rcnt == 11'(NA - 1)) st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- read-out pipeline: RAM read -> rotation (phy_complex_mult)
  logic [31:0] rdata;
  logic        rv1, rvall1, rp1, rs1, rf1, rl1;
  always_ff @(posedge clk) begin
    rdata <= buf_ram[rcnt];
    if (rst) begin rv1 <= 1'b0; rvall1 <= 1'b0; rp1 <= 1'b0; rs1 <= 1'b0; rf1 <= 1'b0; rl1 <= 1'b0; end
    else begin
      rv1    <= (st == S_READ) && !r_is_pil;
      rvall1 <= (st == S_READ);
      rp1    <= (st == S_READ) && r_is_pil;
      rs1    <= rlf[14] ^ rlf[13];
      rf1    <= (st == S_READ) && (rcnt == 11'd0);
      rl1    <= (st == S_READ) && (rcnt == 11'(NA - 1));
    end
  end

  // one more stage so that the per-bin sin/cos (latency 2) lines up with the RAM data
  logic [31:0] rdata2;
  logic        rv2, rvall2, rp2, rs2, rf2, rl2;
  always_ff @(posedge clk) begin
    rdata2 <= rdata;
    if (rst) begin rv2 <= 1'b0; rvall2 <= 1'b0; rp2 <= 1'b0; rs2 <= 1'b0; rf2 <= 1'b0; rl2 <= 1'b0; end
    else begin rv2 <= rv1; rvall2 <= rvall1; rp2 <= rp1; rs2 <= rs1; rf2 <= rf1; rl2 <= rl1; end
  end

  logic        mo_valid;
  logic signed [IQ_W-1:0] mo_i, mo_q;
  phy_complex_mult #(.AW(IQ_W), .BW(16), .FRAC(15)) u_rot (
    .clk, .rst, .in_valid(rvall2), .a(rdata2[31:16]), .b(rdata2[15:0]), .c(SLOPE ? cs_c : c_hold), .d(SLOPE ? cs_s : s_hold),
    .out_valid(mo_valid), .out_i(mo_i), .out_q(mo_q)
  );

  logic [3:0] fpipe, lpipe, ppipe, spipe, apipe;       // first/last/pilot/sign/last-of-read follow the 4-stage multiplier
  always_ff @(posedge clk) begin
    if (rst) begin fpipe <= '0; lpipe <= '0; ppipe <= '0; spipe <= '0; apipe <= '0; end
    else begin
      fpipe <= {fpipe[2:0], rf2}; lpipe <= {lpipe[2:0], rl2 & rv2};
      ppipe <= {ppipe[2:0], rp2}; spipe <= {spipe[2:0], rs2}; apipe <= {apipe[2:0], rl2};
    end
  end

  assign out_valid = mo_valid & ~ppipe[3];
  assign out_re    = mo_i;
  assign out_im    = mo_q;
  assign out_first = fpipe[3];
  assign out_last  = lpipe[3];

  // ---------------------------------------------------------------- pilot L1 error: |re - sigma*A| + |im|, accumulated per symbol
  localparam signed [18:0] AREF = 19'(PILOT_AMP);
  logic signed [18:0] e_r, e_i;
  logic               e_v, e_l;
  logic [18:0]        e_s;
  logic               s_v, s_l;
  always_ff @(posedge clk) begin
    if (rst) begin e_v <= 1'b0; e_l <= 1'b0; s_v <= 1'b0; s_l <= 1'b0; l1_valid <= 1'b0; l1_val <= '0; end
    else begin
      l1_valid <= 1'b0;
      e_v <= mo_valid & ppipe[3];
      e_l <= mo_valid & apipe[3];
      e_r <= 19'(mo_i) - (spipe[3] ? -AREF : AREF);
      e_i <= 19'(mo_q);
      s_v <= e_v; s_l <= e_l;
      e_s <= 19'((e_r[18] ? -e_r : e_r) + (e_i[18] ? -e_i : e_i));
      if (l1_valid) l1_val <= '0;
      else if (s_v) l1_val <= l1_val + 24'(e_s);
      if (s_l) l1_valid <= 1'b1;
    end
  end
endmodule
