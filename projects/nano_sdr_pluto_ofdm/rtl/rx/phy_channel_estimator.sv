// Module : phy_channel_estimator   LS channel estimate from the LTS symbol and equalizer weight computation.
//   For every active bin s (valid-only stream, in_first = s=0): G = Y * sigma_s (sigma from the LTS BPSK LFSR, = H*A),
//   w = A * conj(G) / |G|^2 = (mr + j*mi) * 2^-E with a 16-bit signed mantissa (normalised) and 8-bit signed exponent E.
//   Reciprocal: |G|^2 normalised to M in [2^16, 2^17), 256-entry table + one Newton step (y1 = y0*(2 - M*y0)).
//   The weights are written to an internal RAM (1200 x 40 bit: [39:24]=mr, [23:8]=mi, [7:0]=E) that the equalizer reads
//   through (rd_en, rd_addr) -> rd_data (1 cycle). `done` pulses when the last weight of the frame has been written.
// Latency: 18 cycles from in_valid to the RAM write of the same bin.  Throughput 1 bin/cycle (valid-only).
// DSP: 6 multipliers (2 squares, M*y0, y0*e, 2 weight products).   Golden: python/rx_fixed_ref.py::chest (bit-exact)
module phy_channel_estimator
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   done,
  input  logic                   rd_en,
  input  logic [10:0]            rd_addr,
  output logic [39:0]            rd_data
);
  localparam int NA = NUM_ACTIVE_SC;

  // ---------------------------------------------------------------- A: LFSR sign, address counter
  logic [14:0]  lfsr;
  logic [10:0]  scnt;
  wire  [14:0]  lf_cur = in_first ? LTS_SEED : lfsr;
  wire          sig    = lf_cur[14] ^ lf_cur[13];
  wire  [10:0]  s_cur  = in_first ? 11'd0 : scnt;
  logic         va, la, sa;
  logic [10:0]  aa;
  logic signed [IQ_W-1:0] ya_r, ya_i;
  always_ff @(posedge clk) begin
    if (rst) begin lfsr <= LTS_SEED; scnt <= '0; va <= 1'b0; la <= 1'b0; end
    else begin
      va <= in_valid; la <= in_valid & in_last;
      if (in_valid) begin lfsr <= {lf_cur[13:0], sig}; scnt <= s_cur + 1'b1; end
    end
    if (in_valid) begin ya_r <= in_re; ya_i <= in_im; sa <= sig; aa <= s_cur; end
  end

  // ---------------------------------------------------------------- B: G = Y*sigma, saturated to +-32767
  function automatic logic signed [IQ_W-1:0] sgn_sat(input logic signed [IQ_W-1:0] v, input logic neg);
    logic signed [IQ_W:0] t;
    t = neg ? -(IQ_W+1)'(v) : (IQ_W+1)'(v);
    if (t > 17'sd32767) return 16'sd32767;
    else if (t < -17'sd32767) return -16'sd32767;
    else return t[IQ_W-1:0];
  endfunction
  logic vb, lb;
  logic [10:0] ab;
  logic signed [IQ_W-1:0] gr_b, gi_b;
  always_ff @(posedge clk) begin
    if (rst) begin vb <= 1'b0; lb <= 1'b0; end else begin vb <= va; lb <= la; end
    gr_b <= sgn_sat(ya_r, sa); gi_b <= sgn_sat(ya_i, sa); ab <= aa;
  end

  // ---------------------------------------------------------------- C: squares ; D: |G|^2
  logic vc, lc; logic [10:0] ac; logic signed [IQ_W-1:0] gr_c, gi_c; logic [31:0] sq_r, sq_i;
  always_ff @(posedge clk) begin
    if (rst) begin vc <= 1'b0; lc <= 1'b0; end else begin vc <= vb; lc <= lb; end
    sq_r <= 32'(gr_b) * 32'(gr_b); sq_i <= 32'(gi_b) * 32'(gi_b); gr_c <= gr_b; gi_c <= gi_b; ac <= ab;
  end
  logic vd, ld; logic [10:0] ad; logic signed [IQ_W-1:0] gr_d, gi_d; logic [31:0] m_d;
  always_ff @(posedge clk) begin
    if (rst) begin vd <= 1'b0; ld <= 1'b0; end else begin vd <= vc; ld <= lc; end
    m_d <= sq_r + sq_i; gr_d <= gr_c; gi_d <= gi_c; ad <= ac;
  end

  // ---------------------------------------------------------------- E: leading one position ; F: normalise
  logic ve, le; logic [10:0] ae; logic signed [IQ_W-1:0] gr_e, gi_e; logic [31:0] m_e; logic z_e;
  logic [4:0] p_e, p_e_q;
  always_comb begin
    p_e = '0;
    for (int b = 0; b < 32; b++) if (m_d[b]) p_e = 5'(b);
  end
  always_ff @(posedge clk) begin
    if (rst) begin ve <= 1'b0; le <= 1'b0; end else begin ve <= vd; le <= ld; end
    p_e_q <= p_e; z_e <= (m_d == 32'd0); m_e <= m_d; gr_e <= gr_d; gi_e <= gi_d; ae <= ad;
  end
  logic vf, lf; logic [10:0] af; logic signed [IQ_W-1:0] gr_f, gi_f; logic [16:0] M_f; logic signed [6:0] s_f; logic z_f;
  wire signed [6:0] s_e = $signed({2'b00, p_e_q}) - 7'sd16;
  always_ff @(posedge clk) begin
    if (rst) begin vf <= 1'b0; lf <= 1'b0; end else begin vf <= ve; lf <= le; end
    M_f <= (s_e >= 0) ? 17'(m_e >> s_e) : 17'(m_e << (-s_e));
    s_f <= s_e; z_f <= z_e; gr_f <= gr_e; gi_f <= gi_e; af <= ae;
  end

  // ---------------------------------------------------------------- G: table ; H: M*y0 ; I: 2 - t ; J: y0*e ; K: y1, 3*y1
  logic [15:0] rec_lut [256];
  for (genvar i = 0; i < 256; i++) begin : g_rec
    localparam int RV = $rtoi($floor(65536.0 / (1.0 + (i + 0.5) / 256.0) + 0.5));
    assign rec_lut[i] = 16'(RV);
  end
  logic vg, lg; logic [10:0] ag; logic signed [IQ_W-1:0] gr_g, gi_g; logic [16:0] M_g; logic [15:0] y0_g; logic signed [6:0] s_g; logic z_g;
  always_ff @(posedge clk) begin
    if (rst) begin vg <= 1'b0; lg <= 1'b0; end else begin vg <= vf; lg <= lf; end
    y0_g <= rec_lut[M_f[15:8]]; M_g <= M_f; s_g <= s_f; z_g <= z_f; gr_g <= gr_f; gi_g <= gi_f; ag <= af;
  end
  logic vh, lh; logic [10:0] ah; logic signed [IQ_W-1:0] gr_h, gi_h; logic [15:0] y0_h; logic [32:0] t_h; logic signed [6:0] s_h; logic z_h;
  always_ff @(posedge clk) begin
    if (rst) begin vh <= 1'b0; lh <= 1'b0; end else begin vh <= vg; lh <= lg; end
    t_h <= M_g * y0_g; y0_h <= y0_g; s_h <= s_g; z_h <= z_g; gr_h <= gr_g; gi_h <= gi_g; ah <= ag;
  end
  logic vi, li; logic [10:0] ai; logic signed [IQ_W-1:0] gr_i, gi_i; logic [15:0] y0_i; logic [17:0] e_i; logic signed [6:0] s_i; logic z_i;
  always_ff @(posedge clk) begin
    if (rst) begin vi <= 1'b0; li <= 1'b0; end else begin vi <= vh; li <= lh; end
    e_i <= 18'(18'h20000 - 18'(t_h >> 16)); y0_i <= y0_h; s_i <= s_h; z_i <= z_h; gr_i <= gr_h; gi_i <= gi_h; ai <= ah;
  end
  logic vj, lj; logic [10:0] aj; logic signed [IQ_W-1:0] gr_j, gi_j; logic [33:0] p_j; logic signed [6:0] s_j; logic z_j;
  always_ff @(posedge clk) begin
    if (rst) begin vj <= 1'b0; lj <= 1'b0; end else begin vj <= vi; lj <= li; end
    p_j <= y0_i * e_i; s_j <= s_i; z_j <= z_i; gr_j <= gr_i; gi_j <= gi_i; aj <= ai;
  end
  logic vk, lk; logic [10:0] ak; logic signed [IQ_W-1:0] gr_k; logic signed [IQ_W:0] ngi_k; logic [17:0] k3_k; logic signed [6:0] s_k; logic z_k;
  wire  [33:0] y1_w = (p_j + 34'd32768) >> 16;
  always_ff @(posedge clk) begin
    if (rst) begin vk <= 1'b0; lk <= 1'b0; end else begin vk <= vj; lk <= lj; end
    k3_k <= 18'(y1_w) + 18'(y1_w << 1); s_k <= s_j; z_k <= z_j; gr_k <= gr_j; ngi_k <= -(IQ_W+1)'(gi_j); ak <= aj;
  end

  // ---------------------------------------------------------------- L: weight products ; M1: abs ; M2: max ; N: bit length
  logic vl, ll; logic [10:0] al; logic signed [33:0] pr_l, pi_l; logic signed [6:0] s_l; logic z_l;
  always_ff @(posedge clk) begin
    if (rst) begin vl <= 1'b0; ll <= 1'b0; end else begin vl <= vk; ll <= lk; end
    pr_l <= 34'(gr_k) * 34'($signed({1'b0, k3_k}));
    pi_l <= 34'(ngi_k) * 34'($signed({1'b0, k3_k}));
    s_l <= s_k; z_l <= z_k; al <= ak;
  end
  logic vm1, lm1; logic [10:0] am1; logic signed [33:0] pr_m1, pi_m1; logic [33:0] apr_m1, api_m1; logic signed [6:0] s_m1; logic z_m1;
  always_ff @(posedge clk) begin
    if (rst) begin vm1 <= 1'b0; lm1 <= 1'b0; end else begin vm1 <= vl; lm1 <= ll; end
    apr_m1 <= pr_l[33] ? 34'(-pr_l) : 34'(pr_l);
    api_m1 <= pi_l[33] ? 34'(-pi_l) : 34'(pi_l);
    pr_m1 <= pr_l; pi_m1 <= pi_l; s_m1 <= s_l; z_m1 <= z_l; am1 <= al;
  end
  logic vm, lm; logic [10:0] am; logic signed [33:0] pr_m, pi_m; logic [33:0] mx_m; logic signed [6:0] s_m; logic z_m;
  always_ff @(posedge clk) begin
    if (rst) begin vm <= 1'b0; lm <= 1'b0; end else begin vm <= vm1; lm <= lm1; end
    mx_m <= (apr_m1 > api_m1) ? apr_m1 : api_m1; pr_m <= pr_m1; pi_m <= pi_m1; s_m <= s_m1; z_m <= z_m1; am <= am1;
  end
  logic vn, ln; logic [10:0] an; logic signed [33:0] pr_n, pi_n; logic [5:0] sh1_n; logic signed [6:0] s_n; logic z_n;
  logic [6:0] bl;
  always_comb begin
    bl = '0;
    for (int b = 0; b < 34; b++) if (mx_m[b]) bl = 7'(b + 1);
  end
  always_ff @(posedge clk) begin
    if (rst) begin vn <= 1'b0; ln <= 1'b0; end else begin vn <= vm; ln <= lm; end
    sh1_n <= (bl > 7'd15) ? 6'(bl - 7'd15) : 6'd0; pr_n <= pr_m; pi_n <= pi_m; s_n <= s_m; z_n <= z_m; an <= am;
  end

  // ---------------------------------------------------------------- O1: rounding add ; O2: shift ; O3: saturate + pack
  logic vo1, lo1; logic [10:0] ao1; logic signed [34:0] rr_o1, ri_o1; logic [5:0] sh1_o1; logic signed [6:0] s_o1; logic z_o1;
  wire signed [34:0] rnd = (35'sd1 <<< sh1_n) >>> 1;
  always_ff @(posedge clk) begin
    if (rst) begin vo1 <= 1'b0; lo1 <= 1'b0; end else begin vo1 <= vn; lo1 <= ln; end
    rr_o1 <= 35'(pr_n) + rnd; ri_o1 <= 35'(pi_n) + rnd; sh1_o1 <= sh1_n; s_o1 <= s_n; z_o1 <= z_n; ao1 <= an;
  end
  logic vo2, lo2; logic [10:0] ao2; logic signed [34:0] sr_o2, si_o2; logic [5:0] sh1_o2; logic signed [6:0] s_o2; logic z_o2;
  always_ff @(posedge clk) begin
    if (rst) begin vo2 <= 1'b0; lo2 <= 1'b0; end else begin vo2 <= vo1; lo2 <= lo1; end
    sr_o2 <= rr_o1 >>> sh1_o1; si_o2 <= ri_o1 >>> sh1_o1; sh1_o2 <= sh1_o1; s_o2 <= s_o1; z_o2 <= z_o1; ao2 <= ao1;
  end
  logic vo, lo; logic [10:0] ao; logic [39:0] w_o;
  function automatic logic signed [15:0] sat_m(input logic signed [34:0] v);
    return (v > 35'sd32767) ? 16'sd32767 : (v < -35'sd32767) ? -16'sd32767 : v[15:0];
  endfunction
  wire signed [7:0] E_n = 8'sd20 + 8'(s_o2) - 8'(sh1_o2);
  always_ff @(posedge clk) begin
    if (rst) begin vo <= 1'b0; lo <= 1'b0; end else begin vo <= vo2; lo <= lo2; end
    w_o <= z_o2 ? 40'd0 : {sat_m(sr_o2), sat_m(si_o2), E_n};
    ao <= ao2;
  end

  // ---------------------------------------------------------------- weight RAM (write at stage O, synchronous read port)
  logic [39:0] wram [NA];
  always_ff @(posedge clk) begin
    if (vo) wram[ao] <= w_o;
    if (rd_en) rd_data <= wram[rd_addr];
  end
  always_ff @(posedge clk) begin
    if (rst) done <= 1'b0; else done <= vo & lo;
  end
endmodule
