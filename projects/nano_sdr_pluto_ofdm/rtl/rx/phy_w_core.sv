// Module : phy_w_core   equalizer weight of one bin from its channel value:  w = A * conj(G) / |G|^2 = (mr + j*mi) * 2^-E.
//   The arithmetic of phy_channel_estimator stages C .. O as a stand-alone stream block (same table, Newton step, rounding and packing),
//   used by the code-aided refinement (phy_ca_refine), which must not disturb the estimator of the base receiver.
//   out_w = {mr[15:0], mi[15:0], E[7:0]} (0 for G = 0), out_addr = in_addr.
// Valid-only, latency 16 cycles, throughput 1 bin/cycle, 6 multipliers.   Golden: python/rx_fixed_ref.py::chest_one (bit-exact)
module phy_w_core
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic [10:0]            in_addr,
  input  logic signed [IQ_W-1:0] in_re,          // G, already limited to +-32767
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic [10:0]            out_addr,
  output logic [39:0]            out_w
);
  // ---------------------------------------------------------------- C: squares ; D: |G|^2
  logic vc; logic [10:0] ac; logic signed [IQ_W-1:0] gr_c, gi_c; logic [31:0] sq_r, sq_i;
  always_ff @(posedge clk) begin
    if (rst) vc <= 1'b0; else vc <= in_valid;
    sq_r <= 32'(in_re) * 32'(in_re); sq_i <= 32'(in_im) * 32'(in_im); gr_c <= in_re; gi_c <= in_im; ac <= in_addr;
  end
  logic vd; logic [10:0] ad; logic signed [IQ_W-1:0] gr_d, gi_d; logic [31:0] m_d;
  always_ff @(posedge clk) begin
    if (rst) vd <= 1'b0; else vd <= vc;
    m_d <= sq_r + sq_i; gr_d <= gr_c; gi_d <= gi_c; ad <= ac;
  end

  // ---------------------------------------------------------------- E: leading one position ; F: normalise
  logic ve; logic [10:0] ae; logic signed [IQ_W-1:0] gr_e, gi_e; logic [31:0] m_e; logic z_e;
  logic [4:0] p_e, p_e_q;
  always_comb begin
    p_e = '0;
    for (int b = 0; b < 32; b++) if (m_d[b]) p_e = 5'(b);
  end
  always_ff @(posedge clk) begin
    if (rst) ve <= 1'b0; else ve <= vd;
    p_e_q <= p_e; z_e <= (m_d == 32'd0); m_e <= m_d; gr_e <= gr_d; gi_e <= gi_d; ae <= ad;
  end
  logic vf; logic [10:0] af; logic signed [IQ_W-1:0] gr_f, gi_f; logic [16:0] M_f; logic signed [6:0] s_f; logic z_f;
  wire signed [6:0] s_e = $signed({2'b00, p_e_q}) - 7'sd16;
  always_ff @(posedge clk) begin
    if (rst) vf <= 1'b0; else vf <= ve;
    M_f <= (s_e >= 0) ? 17'(m_e >> s_e) : 17'(m_e << (-s_e));
    s_f <= s_e; z_f <= z_e; gr_f <= gr_e; gi_f <= gi_e; af <= ae;
  end

  // ---------------------------------------------------------------- G: table ; H: M*y0 ; I: 2 - t ; J: y0*e ; K: y1, 3*y1
  logic [15:0] rec_lut [256];
  for (genvar i = 0; i < 256; i++) begin : g_rec
    localparam int RV = $rtoi($floor(65536.0 / (1.0 + (i + 0.5) / 256.0) + 0.5));
    assign rec_lut[i] = 16'(RV);
  end
  logic vg; logic [10:0] ag; logic signed [IQ_W-1:0] gr_g, gi_g; logic [16:0] M_g; logic [15:0] y0_g; logic signed [6:0] s_g; logic z_g;
  always_ff @(posedge clk) begin
    if (rst) vg <= 1'b0; else vg <= vf;
    y0_g <= rec_lut[M_f[15:8]]; M_g <= M_f; s_g <= s_f; z_g <= z_f; gr_g <= gr_f; gi_g <= gi_f; ag <= af;
  end
  logic vh; logic [10:0] ah; logic signed [IQ_W-1:0] gr_h, gi_h; logic [15:0] y0_h; logic [32:0] t_h; logic signed [6:0] s_h; logic z_h;
  always_ff @(posedge clk) begin
    if (rst) vh <= 1'b0; else vh <= vg;
    t_h <= M_g * y0_g; y0_h <= y0_g; s_h <= s_g; z_h <= z_g; gr_h <= gr_g; gi_h <= gi_g; ah <= ag;
  end
  logic vi; logic [10:0] ai; logic signed [IQ_W-1:0] gr_i, gi_i; logic [15:0] y0_i; logic [17:0] e_i; logic signed [6:0] s_i; logic z_i;
  always_ff @(posedge clk) begin
    if (rst) vi <= 1'b0; else vi <= vh;
    e_i <= 18'(18'h20000 - 18'(t_h >> 16)); y0_i <= y0_h; s_i <= s_h; z_i <= z_h; gr_i <= gr_h; gi_i <= gi_h; ai <= ah;
  end
  logic vj; logic [10:0] aj; logic signed [IQ_W-1:0] gr_j, gi_j; logic [33:0] p_j; logic signed [6:0] s_j; logic z_j;
  always_ff @(posedge clk) begin
    if (rst) vj <= 1'b0; else vj <= vi;
    p_j <= y0_i * e_i; s_j <= s_i; z_j <= z_i; gr_j <= gr_i; gi_j <= gi_i; aj <= ai;
  end
  logic vk; logic [10:0] ak; logic signed [IQ_W-1:0] gr_k; logic signed [IQ_W:0] ngi_k; logic [17:0] k3_k; logic signed [6:0] s_k; logic z_k;
  wire  [33:0] y1_w = (p_j + 34'd32768) >> 16;
  always_ff @(posedge clk) begin
    if (rst) vk <= 1'b0; else vk <= vj;
    k3_k <= 18'(y1_w) + 18'(y1_w << 1); s_k <= s_j; z_k <= z_j; gr_k <= gr_j; ngi_k <= -(IQ_W+1)'(gi_j); ak <= aj;
  end

  // ---------------------------------------------------------------- L: weight products ; M1: abs ; M2: max ; N: bit length
  logic vl; logic [10:0] al; logic signed [33:0] pr_l, pi_l; logic signed [6:0] s_l; logic z_l;
  always_ff @(posedge clk) begin
    if (rst) vl <= 1'b0; else vl <= vk;
    pr_l <= 34'(gr_k) * 34'($signed({1'b0, k3_k}));
    pi_l <= 34'(ngi_k) * 34'($signed({1'b0, k3_k}));
    s_l <= s_k; z_l <= z_k; al <= ak;
  end
  logic vm1; logic [10:0] am1; logic signed [33:0] pr_m1, pi_m1; logic [33:0] apr_m1, api_m1; logic signed [6:0] s_m1; logic z_m1;
  always_ff @(posedge clk) begin
    if (rst) vm1 <= 1'b0; else vm1 <= vl;
    apr_m1 <= pr_l[33] ? 34'(-pr_l) : 34'(pr_l);
    api_m1 <= pi_l[33] ? 34'(-pi_l) : 34'(pi_l);
    pr_m1 <= pr_l; pi_m1 <= pi_l; s_m1 <= s_l; z_m1 <= z_l; am1 <= al;
  end
  logic vm; logic [10:0] am; logic signed [33:0] pr_m, pi_m; logic [33:0] mx_m; logic signed [6:0] s_m; logic z_m;
  always_ff @(posedge clk) begin
    if (rst) vm <= 1'b0; else vm <= vm1;
    mx_m <= (apr_m1 > api_m1) ? apr_m1 : api_m1; pr_m <= pr_m1; pi_m <= pi_m1; s_m <= s_m1; z_m <= z_m1; am <= am1;
  end
  logic vn; logic [10:0] an; logic signed [33:0] pr_n, pi_n; logic [5:0] sh1_n; logic signed [6:0] s_n; logic z_n;
  logic [6:0] bl;
  always_comb begin
    bl = '0;
    for (int b = 0; b < 34; b++) if (mx_m[b]) bl = 7'(b + 1);
  end
  always_ff @(posedge clk) begin
    if (rst) vn <= 1'b0; else vn <= vm;
    sh1_n <= (bl > 7'd15) ? 6'(bl - 7'd15) : 6'd0; pr_n <= pr_m; pi_n <= pi_m; s_n <= s_m; z_n <= z_m; an <= am;
  end

  // ---------------------------------------------------------------- O1: rounding add ; O2: shift ; O3: saturate + pack
  logic vo1; logic [10:0] ao1; logic signed [34:0] rr_o1, ri_o1; logic [5:0] sh1_o1; logic signed [6:0] s_o1; logic z_o1;
  wire signed [34:0] rnd = (35'sd1 <<< sh1_n) >>> 1;
  always_ff @(posedge clk) begin
    if (rst) vo1 <= 1'b0; else vo1 <= vn;
    rr_o1 <= 35'(pr_n) + rnd; ri_o1 <= 35'(pi_n) + rnd; sh1_o1 <= sh1_n; s_o1 <= s_n; z_o1 <= z_n; ao1 <= an;
  end
  logic vo2; logic [10:0] ao2; logic signed [34:0] sr_o2, si_o2; logic [5:0] sh1_o2; logic signed [6:0] s_o2; logic z_o2;
  always_ff @(posedge clk) begin
    if (rst) vo2 <= 1'b0; else vo2 <= vo1;
    sr_o2 <= rr_o1 >>> sh1_o1; si_o2 <= ri_o1 >>> sh1_o1; sh1_o2 <= sh1_o1; s_o2 <= s_o1; z_o2 <= z_o1; ao2 <= ao1;
  end
  function automatic logic signed [15:0] sat_m(input logic signed [34:0] v);
    return (v > 35'sd32767) ? 16'sd32767 : (v < -35'sd32767) ? -16'sd32767 : v[15:0];
  endfunction
  wire signed [7:0] E_n = 8'sd20 + 8'(s_o2) - 8'(sh1_o2);
  always_ff @(posedge clk) begin
    if (rst) out_valid <= 1'b0; else out_valid <= vo2;
    out_w <= z_o2 ? 40'd0 : {sat_m(sr_o2), sat_m(si_o2), E_n};
    out_addr <= ao2;
  end
endmodule
