// Module : phy_sync_sc   Schmidl-Cox packet detector + coarse timing + fractional-CFO measurement.
// Function (see python/sync_ref.py, bit-exact golden):
//   P[n] = running sum over the last L products conj(r[n-L])*r[n] (>>QSH),  R[n] = energy of the last L samples (>>QSH)
//   mag  = alpha-max-beta-min |P| ;  cond = (R >= rmin) && (mag > R/2) ;  S = box sum (BOX samples) of (cond ? mag : 0)
//   First cond starts a TRACK window of TRACK_LEN samples; the maximum of S gives n_best (sample index of the smoothed
//   metric peak) and the P snapshot used for the fractional CFO: eps = angle(P)/pi subcarriers,
//   NCO phase increment per sample = angle(P)/L  (2^32 = 2*pi).  Then ev_valid pulses once (det_done stays high until rearm).
//   Calibration (python/sync_test.py): sync-symbol start s0 = n_best - 2184 (+-20), LTS FFT window start = n_best + 104.
// Input: in_valid strobes one complex sample (16-bit signed I/Q; DC must be removed upstream, a DC offset is periodic
//   and would trigger the detector). Pipeline is fully registered, no stalls, accepts 1 sample/clock.
// Latency: ~14 cycles from the TRACK_LEN-th valid sample to ev_valid.   DSP: 6 multipliers (16x16).
// Widths: P 40 bit, R 40 bit, S 48 bit (no overflow for 16-bit input).   Rounding: arithmetic floor shifts.
module phy_sync_sc #(
  parameter int L         = 1024,
  parameter int QSH       = 8,
  parameter int BOX       = 128,
  parameter int TRACK_LEN = 704
) (
  input  logic               clk,
  input  logic               rst,
  input  logic               in_valid,
  input  logic signed [15:0] in_i,
  input  logic signed [15:0] in_q,
  input  logic [31:0]        rmin,
  input  logic               rearm,
  output logic               ev_valid,
  output logic [31:0]        ev_n_decl,
  output logic [31:0]        ev_n_best,
  output logic signed [39:0] ev_p_re,
  output logic signed [39:0] ev_p_im,
  output logic               det_done
);
  localparam int PW = 40;
  localparam int SW = 48;

  // ---------------------------------------------------------------- S0: input + delayed sample
  logic signed [15:0] r0_i, r0_q;
  logic               v0;
  logic [31:0]        rl_raw;
  phy_delay_line #(.W(32), .DEPTH(L)) u_dl_r (.clk, .rst, .in_valid, .in_data({in_i, in_q}), .out_data(rl_raw));
  always_ff @(posedge clk) begin
    if (rst) v0 <= 1'b0; else v0 <= in_valid;
    r0_i <= in_i; r0_q <= in_q;
  end
  wire signed [15:0] rl_i = rl_raw[31:16];
  wire signed [15:0] rl_q = rl_raw[15:0];

  // ---------------------------------------------------------------- S1: products
  logic signed [31:0] p_ii, p_qq, p_iq, p_qi, p_ri, p_rq;
  logic               v1;
  always_ff @(posedge clk) begin
    p_ii <= rl_i * r0_i;
    p_qq <= rl_q * r0_q;
    p_iq <= rl_i * r0_q;
    p_qi <= rl_q * r0_i;
    p_ri <= r0_i * r0_i;
    p_rq <= r0_q * r0_q;
    if (rst) v1 <= 1'b0; else v1 <= v0;
  end

  // ---------------------------------------------------------------- S2: q, e (>> QSH)
  logic signed [24:0] q_r, q_i, e_s;
  logic               v2;
  wire  signed [32:0] qr_f = 33'(p_ii) + 33'(p_qq);
  wire  signed [32:0] qi_f = 33'(p_iq) - 33'(p_qi);
  wire  signed [32:0] e_f  = 33'(p_ri) + 33'(p_rq);
  always_ff @(posedge clk) begin
    q_r <= 25'(qr_f >>> QSH);
    q_i <= 25'(qi_f >>> QSH);
    e_s <= 25'(e_f >>> QSH);
    if (rst) v2 <= 1'b0; else v2 <= v1;
  end

  // ---------------------------------------------------------------- S3: subtract the products of L samples ago
  logic [74:0]        qd_raw;
  phy_delay_line #(.W(75), .DEPTH(L)) u_dl_q (.clk, .rst, .in_valid(v2), .in_data({q_r, q_i, e_s}), .out_data(qd_raw));
  logic signed [24:0] q_r3, q_i3, e_s3;
  logic               v3;
  always_ff @(posedge clk) begin
    q_r3 <= q_r; q_i3 <= q_i; e_s3 <= e_s;
    if (rst) v3 <= 1'b0; else v3 <= v2;
  end
  wire signed [24:0] qo_r = qd_raw[74:50];
  wire signed [24:0] qo_i = qd_raw[49:25];
  wire signed [24:0] eo   = qd_raw[24:0];

  logic signed [25:0] d_r, d_i, d_e;
  logic               v4;
  always_ff @(posedge clk) begin
    d_r <= 26'(q_r3) - 26'(qo_r);
    d_i <= 26'(q_i3) - 26'(qo_i);
    d_e <= 26'(e_s3) - 26'(eo);
    if (rst) v4 <= 1'b0; else v4 <= v3;
  end

  // ---------------------------------------------------------------- S5: running sums
  logic signed [PW-1:0] P_r, P_i, R_s;
  logic                 v5;
  always_ff @(posedge clk) begin
    if (rst) begin P_r <= '0; P_i <= '0; R_s <= '0; v5 <= 1'b0; end
    else begin
      v5 <= v4;
      if (v4) begin
        P_r <= P_r + PW'(d_r);
        P_i <= P_i + PW'(d_i);
        R_s <= R_s + PW'(d_e);
      end
    end
  end

  // ---------------------------------------------------------------- S6a: |P| components ; S6: max/min
  logic [PW-1:0] a6a, b6a;
  logic signed [PW-1:0] pr6a, pi6a, r6a;
  logic          v6a;
  always_ff @(posedge clk) begin
    a6a <= P_r[PW-1] ? PW'(-P_r) : PW'(P_r);
    b6a <= P_i[PW-1] ? PW'(-P_i) : PW'(P_i);
    pr6a <= P_r; pi6a <= P_i; r6a <= R_s;
    if (rst) v6a <= 1'b0; else v6a <= v5;
  end
  logic [PW-1:0] mx6, mn6;
  logic signed [PW-1:0] pr6, pi6, r6;
  logic          v6;
  always_ff @(posedge clk) begin
    mx6 <= (a6a > b6a) ? a6a : b6a;
    mn6 <= (a6a > b6a) ? b6a : a6a;
    pr6 <= pr6a; pi6 <= pi6a; r6 <= r6a;
    if (rst) v6 <= 1'b0; else v6 <= v6a;
  end

  // ---------------------------------------------------------------- S7: magnitude
  logic [PW-1:0] mag7;
  logic signed [PW-1:0] pr7, pi7, r7;
  logic          v7;
  always_ff @(posedge clk) begin
    mag7 <= mx6 + (mn6 >> 1) - (mn6 >> 3);
    pr7 <= pr6; pi7 <= pi6; r7 <= r6;
    if (rst) v7 <= 1'b0; else v7 <= v6;
  end

  // ---------------------------------------------------------------- S8a: comparisons ; S8: condition and gated magnitude
  logic          ge8a, gt8a, v8a;
  logic [PW-1:0] mag8a;
  logic signed [PW-1:0] pr8a, pi8a;
  always_ff @(posedge clk) begin
    ge8a  <= (r7 >= $signed({8'b0, rmin}));
    gt8a  <= ({1'b0, mag7} > {1'b0, PW'(r7 >>> 1)});
    mag8a <= mag7; pr8a <= pr7; pi8a <= pi7;
    if (rst) v8a <= 1'b0; else v8a <= v7;
  end
  logic [PW-1:0] mc8;
  logic          cond8;
  logic signed [PW-1:0] pr8, pi8;
  logic          v8;
  wire           cond7 = ge8a && gt8a;
  always_ff @(posedge clk) begin
    cond8 <= cond7;
    mc8   <= cond7 ? mag8a : '0;
    pr8 <= pr8a; pi8 <= pi8a;
    if (rst) v8 <= 1'b0; else v8 <= v8a;
  end

  // ---------------------------------------------------------------- S9/S10: box sum of the gated magnitude
  logic [SW-1:0] mcd_raw;
  phy_delay_line #(.W(SW), .DEPTH(BOX)) u_dl_m (.clk, .rst, .in_valid(v8), .in_data(SW'(mc8)), .out_data(mcd_raw));
  logic [SW-1:0] mc9;
  logic          cond9, v9;
  logic signed [PW-1:0] pr9, pi9;
  always_ff @(posedge clk) begin
    mc9 <= SW'(mc8); cond9 <= cond8; pr9 <= pr8; pi9 <= pi8;
    if (rst) v9 <= 1'b0; else v9 <= v8;
  end
  logic signed [SW:0] dm;
  logic               cond10, v10;
  logic signed [PW-1:0] pr10, pi10;
  always_ff @(posedge clk) begin
    dm <= (SW+1)'($signed({1'b0, mc9})) - (SW+1)'($signed({1'b0, mcd_raw}));
    cond10 <= cond9; pr10 <= pr9; pi10 <= pi9;
    if (rst) v10 <= 1'b0; else v10 <= v9;
  end
  logic [SW-1:0] S_sum;
  logic          cond11, v11;
  logic signed [PW-1:0] pr11, pi11;
  always_ff @(posedge clk) begin
    if (rst) begin S_sum <= '0; v11 <= 1'b0; end
    else begin
      v11 <= v10;
      if (v10) S_sum <= S_sum + SW'(dm);
    end
    cond11 <= cond10; pr11 <= pr10; pi11 <= pi10;
  end

  // ---------------------------------------------------------------- S12: detection FSM (v11 = one evaluation per sample)
  // S_sum / cond11 / pr11 / pi11 belong to the sample evaluated when v11 is high (registered together with S_sum update:
  // S_sum already includes this sample, cond11/pr11/pi11 are the matching delayed values).
  typedef enum logic [1:0] {ST_IDLE, ST_TRACK, ST_DONE} st_t;
  st_t          st;
  logic [31:0]  nidx;                    // sample index of the sample currently evaluated
  logic [31:0]  tcnt;
  logic [SW-1:0] sbest;
  logic         sbest_none;
  logic [31:0]  nbest;
  logic signed [PW-1:0] psn_r, psn_i;

  assign det_done = (st == ST_DONE);

  always_ff @(posedge clk) begin
    ev_valid <= 1'b0;
    if (rst) begin
      st <= ST_IDLE; nidx <= '0; tcnt <= '0; sbest <= '0; sbest_none <= 1'b1; nbest <= '0;
      psn_r <= '0; psn_i <= '0;
      ev_n_decl <= '0; ev_n_best <= '0; ev_p_re <= '0; ev_p_im <= '0;
    end else begin
      if (rearm) begin st <= ST_IDLE; end
      if (v11) begin
        nidx <= nidx + 1'b1;
        if (st == ST_IDLE && cond11) begin
          st <= ST_TRACK; tcnt <= 32'd1; sbest <= S_sum; sbest_none <= 1'b0; nbest <= nidx; psn_r <= pr11; psn_i <= pi11;
          if (TRACK_LEN == 1) begin st <= ST_DONE; ev_valid <= 1'b1; ev_n_decl <= nidx; ev_n_best <= nidx; ev_p_re <= pr11; ev_p_im <= pi11; end
        end else if (st == ST_TRACK) begin
          if (S_sum > sbest) begin sbest <= S_sum; nbest <= nidx; psn_r <= pr11; psn_i <= pi11; end
          tcnt <= tcnt + 1'b1;
          if (tcnt == 32'(TRACK_LEN - 1)) begin
            st <= ST_DONE; ev_valid <= 1'b1; ev_n_decl <= nidx;
            if (S_sum > sbest) begin ev_n_best <= nidx; ev_p_re <= pr11; ev_p_im <= pi11; end
            else               begin ev_n_best <= nbest; ev_p_re <= psn_r; ev_p_im <= psn_i; end
          end
        end
      end
    end
  end
endmodule
