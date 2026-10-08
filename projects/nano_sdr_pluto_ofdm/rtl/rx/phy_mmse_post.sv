// Module : phy_mmse_post   per-bin post-processing after the LTS: MMSE shrink of the equalizer weights and soft-demapper parameters.
//   Starts when both the channel estimate (`chest_done`) and the noise estimate (`nu_valid`, lg_nu) of the current packet are known
//   and walks the 1200 active bins once (1 bin / cycle, ~12 cycles latency):
//        d   = lg|G|^2 - lg_nu  (log2 * 32, clamped to [D_MIN, D_MAX]);  table index (d - D_MIN) / D_STEP
//        MMSE: mu = 1/(1+2^-d) (Q16);  w <- w * mu (mr, mi rewritten, E kept);  T = 2*QAM_UNIT*mu;  gain log = log2(1+2^d)*32
//        ZF  : weights untouched;                                           T = 2*QAM_UNIT;     gain log = d
//        ge = gain_log >> 5 (floor), gm = EXP2[gain_log & 31]  (32..63)
//   Quality: minimum SNR code and number of bins below cfg_bad_thr are collected during the walk, the average SNR code comes from
//   lgcode(sig_sum) - lg(1200) - lg_nu (q_valid pulse).  Golden: phy2_fixed_ref.quality_codes.
//   Data bins (index % 12 != PILOT_OFFSET) are stored in data-bin order in the parameter RAM {T[15:0], gm[5:0], ge[6:0]} that
//   phy_llr_demap reads (prm_ra -> prm_rd, 1 cycle).  `ready` is high from the end of the walk until `clr`.
// DSP: 2 (weight products).   Golden: python/phy2_fixed_ref.py::post_engine (bit-exact)
module phy_mmse_post
  import phy_pkg::*;
  import phy_soft_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   clr,            // new packet: forget the previous estimate
  input  logic                   cfg_mmse,       // 1 = MMSE, 0 = ZF (reference)
  input  logic                   chest_done,
  input  logic                   nu_valid,
  input  logic signed [12:0]     lg_nu,
  output logic [10:0]            eng_ra,
  input  logic [39:0]            eng_rw,
  input  logic signed [11:0]     eng_rlg,
  output logic                   eng_we,
  output logic [10:0]            eng_wa,
  output logic [39:0]            eng_wd,
  input  logic [10:0]            prm_ra,
  output logic [28:0]            prm_rd,
  output logic                   ready,
  output logic                   busy,
  // channel quality (valid with q_valid, ~8 cycles after ready): codes are log2 * 32 (dB = code * 0.0941)
  input  logic [41:0]            sig_sum,        // sum of |G|^2 from the estimator
  input  logic signed [12:0]     cfg_bad_thr,    // a bin is "bad" when its SNR code is below this (default 106 = 10 dB)
  output logic                   q_valid,
  output logic signed [12:0]     q_snr_avg,
  output logic signed [12:0]     q_snr_min,
  output logic [10:0]            q_bad
);
  localparam int NA = NUM_ACTIVE_SC;

  logic v1, v2, v3, v4, v5, v6, l6;
  logic have_c, have_n, mode_q, started;
  logic signed [12:0] nu_q;
  logic run;
  logic [10:0] k;
  logic [3:0]  kmod;
  logic        v0, p0;

  always_ff @(posedge clk) begin
    if (rst || clr) begin
      have_c <= 1'b0; have_n <= 1'b0; run <= 1'b0; ready <= 1'b0; k <= '0; kmod <= '0; started <= 1'b0;
    end else begin
      if (chest_done) have_c <= 1'b1;
      if (nu_valid) begin have_n <= 1'b1; nu_q <= lg_nu; end
      if (!started && have_c && have_n) begin run <= 1'b1; started <= 1'b1; k <= '0; kmod <= '0; mode_q <= cfg_mmse; end
      if (run) begin
        if (k == 11'(NA - 1)) run <= 1'b0;
        k <= k + 1'b1;
        kmod <= (kmod == 4'(PILOT_SPACING - 1)) ? 4'd0 : kmod + 1'b1;
      end
      if (v6 && l6) ready <= 1'b1;
    end
  end
  assign busy   = run || v1 || v2 || v3 || v4 || v5 || v6;
  assign eng_ra = k;
  assign v0 = run;
  assign p0 = (kmod == 4'(PILOT_OFFSET));

  // S1: RAM data in flight
  logic l1, pl1; logic [10:0] k1;
  always_ff @(posedge clk) begin
    if (rst || clr) v1 <= 1'b0; else v1 <= v0;
    k1 <= k; l1 <= (k == 11'(NA - 1)); pl1 <= p0;
  end
  // S2: operands
  logic l2, pl2; logic [10:0] k2; logic [39:0] w2; logic signed [11:0] lg2;
  always_ff @(posedge clk) begin
    if (rst || clr) v2 <= 1'b0; else v2 <= v1;
    k2 <= k1; l2 <= l1; pl2 <= pl1; w2 <= eng_rw; lg2 <= eng_rlg;
  end
  // S3: d, clamp, table index
  logic l3, pl3; logic [10:0] k3; logic [39:0] w3; logic [9:0] idx3;
  logic signed [14:0] d3;
  always_comb begin
    d3 = 15'(lg2) - 15'(nu_q);
    if (d3 < 15'(D_MIN)) d3 = 15'(D_MIN); else if (d3 > 15'(D_MAX)) d3 = 15'(D_MAX);
  end
  always_ff @(posedge clk) begin
    if (rst || clr) v3 <= 1'b0; else v3 <= v2;
    k3 <= k2; l3 <= l2; pl3 <= pl2; w3 <= w2; idx3 <= 10'((d3 - 15'(D_MIN)) >>> 1);
  end
  // S4: table lookup
  logic l4, pl4; logic [10:0] k4; logic [39:0] w4; logic [15:0] mu4; logic signed [11:0] glm4, glz4;
  always_ff @(posedge clk) begin
    if (rst || clr) v4 <= 1'b0; else v4 <= v3;
    k4 <= k3; l4 <= l3; pl4 <= pl3; w4 <= w3;
    mu4 <= MU_ROM[idx3]; glm4 <= GLM_ROM[idx3]; glz4 <= GLZ_ROM[idx3];
  end
  // S5: mode select, weight products, T, gain split
  logic l5, pl5; logic [10:0] k5; logic [7:0] e5; logic signed [32:0] pr5, pi5; logic [15:0] t5; logic [5:0] gmi5; logic signed [6:0] ge5;
  logic signed [11:0] gl4;
  assign gl4 = mode_q ? glm4 : glz4;
  always_ff @(posedge clk) begin
    if (rst || clr) v5 <= 1'b0; else v5 <= v4;
    k5 <= k4; l5 <= l4; pl5 <= pl4; e5 <= w4[7:0];
    pr5 <= 33'($signed(w4[39:24])) * 33'($signed({1'b0, mu4}));
    pi5 <= 33'($signed(w4[23:8]))  * 33'($signed({1'b0, mu4}));
    t5  <= mode_q ? 16'((mu4 + 17'd4) >> 3) : 16'd8192;
    gmi5 <= {1'b0, gl4[4:0]};
    ge5  <= 7'(gl4 >>> 5);
  end
  // S6: round, gm lookup
  logic pl6; logic [10:0] k6; logic [39:0] wd6; logic [28:0] pw6;
  wire signed [32:0] rr = pr5 + 33'sd32768;
  wire signed [32:0] ri = pi5 + 33'sd32768;
  always_ff @(posedge clk) begin
    if (rst || clr) begin v6 <= 1'b0; end else v6 <= v5;
    k6 <= k5; l6 <= l5; pl6 <= pl5;
    wd6 <= {rr[31:16], ri[31:16], e5};
    pw6 <= {t5, EXP2_ROM[gmi5[4:0]], ge5};
  end
  // write: weights (MMSE only) and parameters of the data bins
  // ---- quality metrics (stage S3 has the clamped d of every bin)
  logic signed [12:0] qmin; logic [10:0] qbad; logic qrun;
  always_ff @(posedge clk) begin
    if (rst || clr) begin qmin <= 13'sd4095; qbad <= '0; end
    else begin
      if (v2 && k2 == 11'd0) begin qmin <= 13'(d3); qbad <= (d3 < 15'(cfg_bad_thr)) ? 11'd1 : 11'd0; end
      else if (v2) begin
        if (13'(d3) < qmin) qmin <= 13'(d3);
        if (d3 < 15'(cfg_bad_thr)) qbad <= qbad + 1'b1;
      end
    end
  end
  logic        lg_v; logic signed [12:0] lg_c;
  logic        ready_p, ready_q;
  phy_lgcode #(.W(42)) u_lgs (.clk, .rst, .in_valid(ready_p), .in_x(sig_sum), .out_valid(lg_v), .out_code(lg_c));
  always_ff @(posedge clk) begin
    ready_q <= ready;
    ready_p <= ready & ~ready_q;
    q_valid <= lg_v;
    if (lg_v) begin q_snr_avg <= lg_c - 13'sd327 - nu_q; q_snr_min <= qmin; q_bad <= qbad; end
  end
  assign eng_we = v6 & mode_q;
  assign eng_wa = k6;
  assign eng_wd = wd6;

  logic [28:0] prm [1100];
  logic [10:0] jw;
  always_ff @(posedge clk) begin
    if (rst || clr) jw <= '0;
    else if (v6 && !pl6) begin prm[jw] <= pw6; jw <= jw + 1'b1; end
    prm_rd <= prm[prm_ra];
  end
endmodule
