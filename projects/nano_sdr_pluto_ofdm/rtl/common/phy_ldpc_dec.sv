// Module : phy_ldpc_dec   QC-LDPC layered normalised min-sum decoder, Z-parallel, two codes on one datapath (cfg_cs):
//   cfg_cs = 0: R = 1/2 (K = 1080, 18 layers, MAX RANGE)   cfg_cs = 1: R = 5/6 (K = 1800, 6 layers, MAX RATE)   N = 2160, Z = 60.
//   Input  : 4 channel LLRs per cycle (6 bit signed, positive = bit 0), 540 words per codeword (natural order, element n = 4*w + j).
//   Output : the information bits as 135 (R = 1/2) or 225 (R = 5/6) bytes (MSB first = lowest bit index), one codeword at a time, status (iterations
//            used, converged flag) valid with the last byte (st_valid).
// Architecture (python/ldpc_fixed_ref.py is the bit-exact golden model):
//   * two banks of 60 x 36 x 8 bit posterior memory (distributed RAM, one 8 bit RAM per circulant element): one bank loads the next
//     codeword while the other decodes or is read out, so load / decode / output overlap;
//   * every column is stored rotated by the shift of the last layer that used it (phy_ldpc_pkg::lcoloff): a single 60 x 8 bit
//     6-stage barrel rotator per read, no inverse rotation, the rotation deltas are constants in the package;
//   * per layer: pass 1 reads the entries (read, rotate, R_old / Q, min-sum accumulation), pass 2 writes L = Q + R_new back; the
//     check-node state of the 6 layers circulates in a shift ring;
//   * early termination after one full clean iteration (6 / 18 consecutive clean layers) (no unsatisfied parity among the read signs and no sign changed on write).
// Cost: ~(2*deg + 8) cycles per layer, ~260 cycles per iteration.
// cfg_post = 1 (code-aided receiver, phy_ca_refine): every codeword is also delivered as 36 columns of hard decisions (col_hard[i] = bit
//   60 * col_idx + i) with a reliability flag per bit (codeword converged, or |posterior| >= REL_THR); the parity columns are read after the
//   last byte, which delays the release of the bank by 3 cycles per column pair. cfg_post = 0: no change of behaviour or timing.
module phy_ldpc_dec
  import phy_ldpc_pkg::*;
#(
  parameter int LW = 8,            // posterior / message width
  parameter int MW = 7,            // check magnitude width (min1 / min2)
  parameter int REL_THR = 24       // |posterior| from which a bit of a non-converged codeword counts as reliable (cfg_post)
) (
  input  logic              clk,
  input  logic              rst,
  input  logic [4:0]        cfg_max_iter,
  input  logic              cfg_cs,            // code select, static while a packet is in flight
  input  logic              cfg_post,          // deliver all columns with reliability flags (static while a packet is in flight)
  input  logic              in_valid,
  output logic              in_ready,
  input  logic signed [5:0] in_llr [4],
  output logic              out_valid,
  output logic              out_first,
  output logic              out_last,
  output logic [7:0]        out_data,
  output logic              st_valid,          // with out_last
  output logic              st_ok,
  output logic [4:0]        st_iter,
  output logic              busy,
  output logic              col_valid,         // cfg_post: column col_idx of the codeword being output
  output logic [5:0]        col_idx,
  output logic [LZ-1:0]     col_hard,
  output logic [LZ-1:0]     col_rel
);
  localparam int Z    = LZ;
  localparam int LMAX = (1 << (LW - 1)) - 1;     // 127
  localparam int MMAX = (1 << MW) - 1;           // 127
  localparam int NW   = LN / 4;                  // 540 words per codeword

  typedef logic signed [LW-1:0] lv_t [Z];

  // ===================================================================== declarations (shared)
  logic        ld_sel, dec_sel, out_sel;
  logic [1:0]  occ, dcd;                          // loaded and not yet output / decoded
  logic [4:0]  res_iter [2];
  logic        res_ok [2];
  logic        out_done_p, out_done_b;                 // output of bank out_done_b finished (one cycle pulse)
  logic [5:0]  out_col_r;

  logic        dw_en;
  logic [5:0]  dw_col;
  lv_t         dw_data;
  (* max_fanout = 24 *) logic [5:0]  rd_addr [2];
  lv_t         rd_data [2];
  (* max_fanout = 24 *) logic [5:0]  s0_col;
  logic        dec_busy;

  assign in_ready = !occ[ld_sel];
  assign busy     = dec_busy || (occ != 2'b00);

  // ===================================================================== loader
  logic [9:0]  ld_w;
  logic [5:0]  ld_col;
  logic [5:0]  ld_r0;                             // element index of j = 0 inside the column (multiple of 4)
  wire         ld_fire = in_valid && in_ready;
  wire  [5:0]  ld_off  = lcoloff(int'(cfg_cs), int'(ld_col));
  logic [5:0]  ld_p [4];
  always_comb begin
    for (int j = 0; j < 4; j++) begin
      logic [7:0] x;
      x = 8'(ld_r0) + 8'(j) + 8'd60 - 8'(ld_off);
      if (x >= 8'd120) x = x - 8'd120; else if (x >= 8'd60) x = x - 8'd60;
      ld_p[j] = x[5:0];
    end
  end

  // write pipeline (timing): element positions / data registered one cycle before the RAM write
  logic        lq_v, lq_sel;
  logic [5:0]  lq_col, lq_p [4];
  logic signed [5:0] lq_d [4];
  always_ff @(posedge clk) begin
    lq_v <= ld_fire && !rst; lq_sel <= ld_sel; lq_col <= ld_col;
    for (int j = 0; j < 4; j++) begin lq_p[j] <= ld_p[j]; lq_d[j] <= in_llr[j]; end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ld_w <= '0; ld_col <= '0; ld_r0 <= '0; ld_sel <= 1'b0; occ <= 2'b00;
    end else begin
      if (ld_fire) begin
        if (ld_w == 10'(NW - 1)) begin
          ld_w <= '0; ld_col <= '0; ld_r0 <= '0; occ[ld_sel] <= 1'b1; ld_sel <= ~ld_sel;
        end else begin
          ld_w <= ld_w + 1'b1;
          if (ld_r0 == 6'd56) begin ld_r0 <= '0; ld_col <= ld_col + 1'b1; end
          else ld_r0 <= ld_r0 + 6'd4;
        end
      end
      if (out_done_p) occ[out_done_b] <= 1'b0;
    end
  end

  // ===================================================================== posterior memories: 2 banks, one block RAM of 36 x (60 x 8 bit) each
  // with a write enable per element (byte): the loader writes 4 elements of a column per cycle, the decoder a whole column. Synchronous read:
  // the RAM output register replaces the former s1_d / raw_q registers (same latency as the registered asynchronous read it replaces).
  // The loader and the decoder never write the same bank at the same time; a column is never read in the cycle it is written.
  genvar gb, gp;
  logic [Z*LW-1:0] rd_q [2];
  generate
    for (gb = 0; gb < 2; gb++) begin : g_bank
      logic [Z-1:0]    l_we;
      logic [Z*LW-1:0] l_d;
      logic [5:0]      l_col;
      for (gp = 0; gp < Z; gp++) begin : g_el
        logic              l_we_c;
        logic signed [5:0] l_d_c;
        always_comb begin
          l_we_c = 1'b0; l_d_c = '0;
          for (int j = 0; j < 4; j++)
            if (lq_v && lq_sel == 1'(gb) && lq_p[j] == 6'(gp)) begin l_we_c = 1'b1; l_d_c = lq_d[j]; end
        end
        always_ff @(posedge clk) begin           // write registers in front of the RAM (timing)
          l_we[gp] <= l_we_c; l_d[gp*LW +: LW] <= LW'(l_d_c);
        end
        assign rd_data[gb][gp] = rd_q[gb][gp*LW +: LW];
      end
      always_ff @(posedge clk) l_col <= lq_col;
      wire             d_we  = dw_en && (dec_sel == 1'(gb));
      wire             l_any = |l_we;
      wire [5:0]       wa    = l_any ? l_col : dw_col;
      logic [Z*LW-1:0] wd;
      logic [Z-1:0]    we;
      always_comb begin
        for (int p = 0; p < Z; p++) begin
          we[p] = l_any ? l_we[p] : d_we;
          wd[p*LW +: LW] = l_any ? l_d[p*LW +: LW] : dw_data[p];
        end
      end
      (* ram_style = "block" *) logic [Z*LW-1:0] pmem [64];
      always_ff @(posedge clk) begin
        for (int p = 0; p < Z; p++) if (we[p]) pmem[wa][p*LW +: LW] <= wd[p*LW +: LW];
      end
      always_ff @(posedge clk) rd_q[gb] <= pmem[rd_addr[gb]];
    end
  endgenerate

  // ===================================================================== decoder datapath state
  logic [MW-1:0]    w_m1 [Z], w_m2 [Z];             // working check-node record of the layer in progress
  logic [4:0]       w_idx [Z];
  logic             w_par [Z];
  logic [LDMAX-1:0] w_sg [Z];
  // layer ring: the check-node record written at the end of a layer is read again lmb layers later (dynamic shift register, tap = lmb - 1)
  localparam int RGW = 2 * MW + 5 + 1 + LDMAX;
  logic [RGW-1:0]   rg_d [Z], rg_q [Z];
  logic             rg_en;
  logic             pr_acc [Z];
  // Q messages of the layer in progress (pass 1 writes, pass 2 reads): 18 x 480 bit, block RAM (was 8.6 k flip-flops + an 18:1 read mux)
  (* ram_style = "block" *) logic [Z*LW-1:0] qbuf [32];
  logic [Z*LW-1:0]  qbuf_q;
  logic [Z-1:0]     lsg [LDMAX];

  typedef enum logic [2:0] {D_IDLE, D_P1, D_P1D, D_P2, D_P2D, D_END} dst_t;
  dst_t        dst;
  logic [4:0]  layer;
  logic [4:0]  e_cnt, e2_cnt;
  logic [4:0]  iter_cnt;
  logic [4:0]  clean_cnt;
  logic        first_iter;
  logic [2:0]  drain;
  logic        unsat_any, flip_any;
  wire  [4:0]  deg_l = 5'(ldeg(int'(cfg_cs), int'(layer)));
  wire  [4:0]  lmb_c = 5'(lmb(int'(cfg_cs)));          // layers of the selected code
  wire  [4:0]  lkb_c = 5'(lkb(int'(cfg_cs)));          // information block columns of the selected code

  // rotation: out[p] = in[(p + sh) % Z] when enabled
  function automatic lv_t rot_stage(input lv_t x, input int sh, input logic en);
    lv_t y;
    for (int p = 0; p < Z; p++) y[p] = en ? x[(p + sh) % Z] : x[p];
    return y;
  endfunction

  // ---- pass 1 pipeline
  logic        s0_v, s1_v, s2_v, s3_v, s4_v, s5_v;
  logic [4:0]  s0_k, s1_k, s2_k, s3_k, s4_k, s5_k;
  logic [5:0]  s0_dl, s1_dl, s2_dl;
  lv_t         s1_d, s2_d, s3_d, s3_r, s4_q, s4_lr, s5_q, s5_lr;
  logic [MW-1:0] s5_am [Z];                       // |s5_q| clamped to MMAX, computed one stage earlier (timing)

  wire issue1 = (dst == D_P1);
  wire issue2 = (dst == D_P2);

  assign rd_addr[0] = (dec_busy && !dec_sel) ? s0_col : out_col_r;
  assign rd_addr[1] = (dec_busy &&  dec_sel) ? s0_col : out_col_r;

  always_comb for (int p = 0; p < Z; p++) s1_d[p] = dec_sel ? rd_data[1][p] : rd_data[0][p];     // RAM output register = stage s1

  lv_t rotA, rotB, rold;
  always_comb begin
    rotA = s1_d;
    rotA = rot_stage(rotA, 1, s1_dl[0]);
    rotA = rot_stage(rotA, 2, s1_dl[1]);
    rotA = rot_stage(rotA, 4, s1_dl[2]);
    rotB = s2_d;
    rotB = rot_stage(rotB, 8,  s2_dl[3]);
    rotB = rot_stage(rotB, 16, s2_dl[4]);
    rotB = rot_stage(rotB, 32, s2_dl[5]);
    for (int r = 0; r < Z; r++) begin
      logic [MW-1:0] mg, sc, m1x, m2x; logic [4:0] ix; logic px; logic [LDMAX-1:0] sx;
      // record of this layer from the previous iteration: tap lmb - 1 of the ring
      m1x = rg_q[r][MW-1:0]; m2x = rg_q[r][2*MW-1:MW]; ix = rg_q[r][2*MW+4:2*MW]; px = rg_q[r][2*MW+5]; sx = rg_q[r][RGW-1:2*MW+6];
      mg = (ix == s2_k) ? m2x : m1x;
      sc = mg - (mg >> 2);
      if (first_iter) rold[r] = '0;
      else rold[r] = (px ^ sx[s2_k]) ? -LW'($signed({1'b0, sc})) : LW'($signed({1'b0, sc}));
    end
  end
  for (genvar gr = 0; gr < Z; gr++) begin : g_ring
    assign rg_d[gr] = {w_sg[gr], w_par[gr], w_idx[gr], w_m2[gr], w_m1[gr]};
    phy_dyn_sr #(.W(RGW), .DEPTH(LMB)) u_rg (.clk, .en(rg_en), .d(rg_d[gr]), .tap(5'(lmb_c - 5'd1)), .q(rg_q[gr]));
  end
  assign rg_en = (dst == D_END);

  always_ff @(posedge clk) begin
    s0_v <= issue1; s0_k <= e_cnt;
    s0_col <= lcol(int'(cfg_cs), int'(layer), int'(e_cnt));
    s0_dl  <= ldelta(int'(cfg_cs), int'(layer), int'(e_cnt));
    s1_v <= s0_v; s1_k <= s0_k; s1_dl <= s0_dl;
    s2_v <= s1_v; s2_k <= s1_k; s2_dl <= s1_dl; s2_d <= rotA;
    s3_v <= s2_v; s3_k <= s2_k; s3_d <= rotB; s3_r <= rold;
    s4_v <= s3_v; s4_k <= s3_k;
    for (int r = 0; r < Z; r++) begin
      logic signed [LW:0] d;
      d = (LW+1)'(s3_d[r]) - (LW+1)'(s3_r[r]);
      if (d > LMAX) s4_q[r] <= LW'(LMAX); else if (d < -LMAX) s4_q[r] <= LW'(-LMAX); else s4_q[r] <= d[LW-1:0];
      s4_lr[r] <= s3_d[r];
    end
    s5_v <= s4_v; s5_k <= s4_k; s5_q <= s4_q; s5_lr <= s4_lr;
    for (int r = 0; r < Z; r++) begin
      logic [LW-1:0] a0;
      a0 = s4_q[r][LW-1] ? LW'(-s4_q[r]) : LW'(s4_q[r]);
      s5_am[r] <= (a0 > LW'(MMAX)) ? MW'(MMAX) : a0[MW-1:0];
    end
  end

  // ---- check-node accumulation (stage s5), buffers, ring
  always_ff @(posedge clk) begin
    if (dst == D_P1 && e_cnt == 5'd0) begin
      for (int r = 0; r < Z; r++) begin
        w_m1[r] <= MW'(MMAX); w_m2[r] <= MW'(MMAX); w_idx[r] <= '0; w_par[r] <= 1'b0; pr_acc[r] <= 1'b0;
      end
    end
    if (s5_v) begin
      for (int r = 0; r < Z; r++) begin
        logic [MW-1:0] am;
        am = s5_am[r];
        if (am < w_m1[r]) begin w_m2[r] <= w_m1[r]; w_m1[r] <= am; w_idx[r] <= s5_k; end
        else if (am < w_m2[r]) w_m2[r] <= am;
        w_par[r] <= w_par[r] ^ s5_q[r][LW-1];
        w_sg[r][s5_k] <= s5_q[r][LW-1];
        pr_acc[r] <= pr_acc[r] ^ s5_lr[r][LW-1];
      end
      for (int r = 0; r < Z; r++) lsg[s5_k][r] <= s5_lr[r][LW-1];
    end
  end
  // Q buffer RAM: write port (stage s5), synchronous read port (pass 2, address e2_cnt -> a1_q)
  logic [Z*LW-1:0] s5_q_flat;
  always_comb for (int r = 0; r < Z; r++) s5_q_flat[r*LW +: LW] = s5_q[r];
  always_ff @(posedge clk) if (s5_v) qbuf[s5_k] <= s5_q_flat;
  always_ff @(posedge clk) qbuf_q <= qbuf[e2_cnt];

  // ---- pass 2 pipeline: a1 (Q, R_new) -> a2 (L_new) -> w (write)
  logic        a1_v, a2_v, w_v;
  logic [4:0]  a1_k, a2_k;
  lv_t         a1_q, a1_rn, a2_l, w_l;
  always_comb for (int r = 0; r < Z; r++) a1_q[r] = qbuf_q[r*LW +: LW];
  logic [5:0]  w_colr, w_shr;
  always_ff @(posedge clk) begin
    a1_v <= issue2; a1_k <= e2_cnt;
    a2_v <= a1_v;   a2_k <= a1_k;
    w_v  <= a2_v;
    for (int r = 0; r < Z; r++) begin
      logic [MW-1:0] mg, sc;
      mg = (w_idx[r] == e2_cnt) ? w_m2[r] : w_m1[r];
      sc = mg - (mg >> 2);
      a1_rn[r] <= (w_par[r] ^ w_sg[r][e2_cnt]) ? -LW'($signed({1'b0, sc})) : LW'($signed({1'b0, sc}));
    end
    for (int r = 0; r < Z; r++) begin
      logic signed [LW:0] d;
      d = (LW+1)'(a1_q[r]) + (LW+1)'(a1_rn[r]);
      if (d > LMAX) a2_l[r] <= LW'(LMAX); else if (d < -LMAX) a2_l[r] <= LW'(-LMAX); else a2_l[r] <= d[LW-1:0];
    end
    w_l <= a2_l;
    w_colr <= lcol(int'(cfg_cs), int'(layer), int'(a2_k));
    w_shr  <= lshift(int'(cfg_cs), int'(layer), int'(a2_k));
  end
  assign dw_en   = w_v;
  assign dw_col  = w_colr;
  always_comb for (int r = 0; r < Z; r++) dw_data[r] = w_l[r];

  // ---- control FSM
  always_ff @(posedge clk) begin
    if (rst) begin
      dst <= D_IDLE; layer <= '0; e_cnt <= '0; e2_cnt <= '0; iter_cnt <= '0; clean_cnt <= '0; first_iter <= 1'b1;
      dec_busy <= 1'b0; dec_sel <= 1'b0; dcd <= 2'b00; drain <= '0; unsat_any <= 1'b0; flip_any <= 1'b0;
    end else begin
      case (dst)
        D_IDLE: begin
          if (occ[dec_sel] && !dcd[dec_sel]) begin
            dec_busy <= 1'b1; layer <= '0; e_cnt <= '0; iter_cnt <= 5'd1; clean_cnt <= '0; first_iter <= 1'b1;
            unsat_any <= 1'b0; flip_any <= 1'b0; dst <= D_P1;
          end
        end
        D_P1: begin
          if (e_cnt + 5'd1 == deg_l) begin dst <= D_P1D; drain <= 3'd6; end
          e_cnt <= e_cnt + 1'b1;
        end
        D_P1D: begin
          if (drain == 3'd0) begin dst <= D_P2; e2_cnt <= '0; end
          else drain <= drain - 1'b1;
        end
        D_P2: begin
          if (e2_cnt + 5'd1 == deg_l) begin dst <= D_P2D; drain <= 3'd3; end
          e2_cnt <= e2_cnt + 1'b1;
        end
        D_P2D: begin
          if (drain == 3'd0) dst <= D_END; else drain <= drain - 1'b1;
        end
        D_END: begin
          logic clean; logic [4:0] cn;
          clean = !unsat_any && !flip_any;
          cn = clean ? ((clean_cnt == 5'd31) ? 5'd31 : clean_cnt + 5'd1) : 5'd0;
          clean_cnt <= cn;
          unsat_any <= 1'b0; flip_any <= 1'b0;
          if (cn >= lmb_c || (layer == lmb_c - 5'd1 && iter_cnt == cfg_max_iter)) begin
            dst <= D_IDLE; dec_busy <= 1'b0; dcd[dec_sel] <= 1'b1;
            res_iter[dec_sel] <= iter_cnt; res_ok[dec_sel] <= (cn >= lmb_c);
            dec_sel <= ~dec_sel;
          end else begin
            e_cnt <= '0;
            if (layer == lmb_c - 5'd1) begin layer <= '0; iter_cnt <= iter_cnt + 1'b1; first_iter <= 1'b0; end
            else layer <= layer + 1'b1;
            dst <= D_P1;
          end
        end
        default: dst <= D_IDLE;
      endcase
      if (out_done_p) dcd[out_done_b] <= 1'b0;
      if (dst == D_P1D && drain == 3'd0) begin            // parity of the signs read in this layer
        logic u; u = 1'b0;
        for (int r = 0; r < Z; r++) u |= pr_acc[r];
        unsat_any <= u;
      end
      if (a2_v) begin                                      // sign changes caused by this entry's write-back
        logic f; f = 1'b0;
        for (int r = 0; r < Z; r++) f |= ((a2_l[r] < 0) != lsg[a2_k][r]);
        if (f) flip_any <= 1'b1;
      end
    end
  end

  // rotation state (offset) of every column of every bank: set to the load placement at the start of decoding, updated on write-back
  logic [5:0] coff [2][LNB];
  always_ff @(posedge clk) begin
    if (dst == D_IDLE && occ[dec_sel] && !dcd[dec_sel])
      for (int c = 0; c < LNB; c++) coff[dec_sel][c] <= lcoloff(int'(cfg_cs), c);
    if (dw_en) coff[dec_sel][dw_col] <= w_shr;
  end

  // ===================================================================== output stage
  typedef enum logic [1:0] {O_IDLE, O_RD, O_SHIFT} ost_t;
  ost_t         ost;
  logic [4:0]   o_pair;
  logic [1:0]   o_cyc;                     // 2 bit counter: 0..3
  logic [Z-1:0] h0, h1;
  logic [3:0]   o_byte;
  logic         o_first;

  // sign vector of the addressed column: captured raw, then rotated back to natural order one cycle later (timing)
  logic [Z-1:0] raw_q, rraw_q;
  logic [5:0]   rotd_q;
  logic [Z-1:0] nat;
  logic         o_par;                     // reading the parity columns (cfg_post)
  always_comb for (int p = 0; p < Z; p++) raw_q[p] = out_sel ? rd_data[1][p][LW-1] : rd_data[0][p][LW-1];   // RAM output register
  always_comb for (int p = 0; p < Z; p++) begin
    logic signed [LW-1:0] lv;
    lv = out_sel ? rd_data[1][p] : rd_data[0][p];
    rraw_q[p] = (lv >= LW'(REL_THR)) || (lv <= -LW'(REL_THR));
  end
  always_ff @(posedge clk) begin
    rotd_q <= (coff[out_sel][out_col_r] == 6'd0) ? 6'd0 : 6'(Z) - coff[out_sel][out_col_r];
  end
  always_comb begin
    logic [Z-1:0] t, u;
    t = raw_q;
    for (int s = 0; s < 6; s++) begin
      for (int p = 0; p < Z; p++) u[p] = rotd_q[s] ? t[(p + (1 << s)) % Z] : t[p];
      t = u;
    end
    nat = t;
  end
  // column port (cfg_post): the raw column is registered first and rotated back one cycle later (timing: RAM output -> compare -> rotator)
  logic         cq_v, cq_ok; logic [5:0] cq_idx, cq_rot; logic [Z-1:0] cq_h, cq_r, cnat_h, cnat_r;
  always_comb begin
    logic [Z-1:0] t, u;
    t = cq_h;
    for (int s = 0; s < 6; s++) begin
      for (int p = 0; p < Z; p++) u[p] = cq_rot[s] ? t[(p + (1 << s)) % Z] : t[p];
      t = u;
    end
    cnat_h = t;
    t = cq_r;
    for (int s = 0; s < 6; s++) begin
      for (int p = 0; p < Z; p++) u[p] = cq_rot[s] ? t[(p + (1 << s)) % Z] : t[p];
      t = u;
    end
    cnat_r = t;
  end
  always_ff @(posedge clk) begin
    cq_v   <= cfg_post && !rst && (ost == O_RD) && (o_cyc == 2'd1 || o_cyc == 2'd2);
    cq_idx <= {o_pair, o_cyc[1]}; cq_ok <= res_ok[out_sel]; cq_rot <= rotd_q; cq_h <= raw_q; cq_r <= rraw_q;
    col_valid <= cq_v && !rst;
    col_idx   <= cq_idx;
    col_hard  <= cnat_h;
    col_rel   <= cnat_r | {Z{cq_ok}};
  end

  logic [119:0] cat;                       // bit i of the two columns (natural order) -> MSB-first byte stream
  always_comb for (int i = 0; i < Z; i++) begin cat[119 - i] = h0[i]; cat[59 - i] = h1[i]; end

  always_ff @(posedge clk) begin
    out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0; st_valid <= 1'b0; out_done_p <= 1'b0;
    if (rst) begin
      ost <= O_IDLE; out_sel <= 1'b0; o_pair <= '0; out_col_r <= '0; o_byte <= '0; o_cyc <= '0; o_first <= 1'b1;
      st_ok <= 1'b0; st_iter <= '0; o_par <= 1'b0;
    end else begin
      case (ost)
        O_IDLE: begin
          o_par <= 1'b0;
          if (dcd[out_sel]) begin ost <= O_RD; o_pair <= '0; out_col_r <= '0; o_cyc <= '0; o_first <= 1'b1; end
        end
        O_RD: begin            // cycle 0: col 2p addressed, raw/offset registered at its end; 1: nat(col 2p) -> h0, col 2p+1 registered; 2: nat(col 2p+1) -> h1
          o_cyc <= o_cyc + 1'b1;
          if (o_cyc == 2'd0) out_col_r <= {o_pair, 1'b0} + 6'd1;
          if (o_cyc == 2'd1) h0 <= nat;
          if (o_cyc == 2'd2) begin
            if (!o_par) begin h1 <= nat; ost <= O_SHIFT; o_byte <= '0; end
            else if (o_pair == 5'(LNB / 2 - 1)) begin out_done_p <= 1'b1; out_done_b <= out_sel; ost <= O_IDLE; out_sel <= ~out_sel; end
            else begin o_pair <= o_pair + 1'b1; o_cyc <= '0; out_col_r <= {(o_pair + 5'd1), 1'b0}; end
          end
        end
        O_SHIFT: begin
          out_valid <= 1'b1;
          out_data  <= cat[119 - 8 * int'(o_byte) -: 8];
          out_first <= o_first; o_first <= 1'b0;
          if (o_byte == 4'd14) begin
            if (o_pair == (lkb_c >> 1) - 5'd1) begin
              out_last <= 1'b1; st_valid <= 1'b1; st_ok <= res_ok[out_sel]; st_iter <= res_iter[out_sel];
              if (cfg_post) begin o_par <= 1'b1; o_pair <= o_pair + 1'b1; ost <= O_RD; o_cyc <= '0; out_col_r <= {(o_pair + 5'd1), 1'b0}; end
              else begin out_done_p <= 1'b1; out_done_b <= out_sel; ost <= O_IDLE; out_sel <= ~out_sel; end
            end else begin
              o_pair <= o_pair + 1'b1; ost <= O_RD; o_cyc <= '0; out_col_r <= {(o_pair + 5'd1), 1'b0};
            end
          end else o_byte <= o_byte + 1'b1;
        end
        default: ost <= O_IDLE;
      endcase
    end
  end
endmodule
