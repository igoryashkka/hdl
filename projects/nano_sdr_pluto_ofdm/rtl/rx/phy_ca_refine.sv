// Module : phy_ca_refine   code-aided channel refinement and second pass of the coded receiver (ТЗ 004, Patch B). A side block: the base
//   receiver chain is not changed, the block listens to it during the first pass and replays the packet once if a codeword failed.
//   First pass (capture):  z = tracker output of the data bins of every data symbol            -> Z buffer (MAX_SYMS x 1100 x 32 bit)
//                          decoder columns (hard decisions + reliability flags, cfg_post)        -> codeword store (2 * MAX_SYMS x 36 x 120 bit)
//                          converged flag of every codeword                                      -> fail map
//   start (first pass finished and a codeword failed):
//     ACC  per symbol, per coded word j: re-modulate the word (x^ in quarter QAM units: QPSK +-9, 16-QAM +-4 / +-12), place it on its data bin
//          m = (j % 55) * 20 + j / 55 (interleaver, odd m: word rotated by one bit for 16-QAM) and, if all its bits are reliable, accumulate
//          S[m] += conj(x^) z ,  Eh[m] += |x^|^2 / 2                                       (1 word / cycle)
//     W    per data bin: N1 = W0H * T + 4 S ,  M1 = T * (W0H + Eh) ,  G = sat16(N1 * 12288 / M1) (reciprocal ROM of the 12 bit mantissa of M1),
//          correction weight = phy_w_core(G) = 1 / c  (c = refined / old channel ratio)   -> weight RAM            (1 bin / cycle)
//     P2   every symbol with a failed codeword: z -> phy_equalizer (correction weights) -> out_* -> demapper / deinterleaver / decoder of the
//          base chain (p2 = 1, p2_skip marks the codewords that are not decoded again). The decoder bytes are descrambled with a local
//          keystream generator (advanced to the byte offset of the codeword) and written to the packet buffer (bw_*).
//     done pulse with the statistics of the second pass (codewords repaired, iterations).
// Timing: ACC nsyms * 1100 cycles, W 1100 + ~30 cycles, P2 per replayed symbol 1100 (replay) + 1100 (deinterleaver) + decode time.
// Resources: 2 + 4 + 6 (phy_w_core) + 4 (equalizer) multipliers, block RAM for the four memories and the reciprocal ROM.
// Golden: python/rxenh_fixed_ref.py::ca_weights / second_pass (bit-exact)
module phy_ca_refine
  import phy_pkg::*;
#(
  parameter int MAX_SYMS = 8,
  parameter int W0H      = 216            // weight of the LTS estimate: 3 smoothing bins * A^2 / 2 in quarter units^2
) (
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   clr,            // new packet
  input  logic                   mode,           // 0: QPSK, 1 codeword / symbol   1: 16-QAM, 2 codewords / symbol (static from the first data symbol)
  input  logic [7:0]             nsyms,
  // first pass
  input  logic                   z_valid,
  input  logic signed [IQ_W-1:0] z_re,
  input  logic signed [IQ_W-1:0] z_im,
  input  logic                   col_valid,
  input  logic [5:0]             col_idx,
  input  logic [59:0]            col_hard,
  input  logic [59:0]            col_rel,
  input  logic                   cw_valid,       // one pulse per codeword of the first pass, in order
  input  logic                   cw_ok,
  input  logic                   start,
  // per-bin parameter RAM of the packet (threshold T)
  output logic                   prm_sel,
  output logic [10:0]            prm_ra,
  input  logic [28:0]            prm_rd,
  // second pass
  output logic                   p2,
  output logic [1:0]             p2_skip,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im,
  input  logic                   raw_valid,
  input  logic [7:0]             raw_data,
  input  logic                   raw_st_valid,
  input  logic                   raw_st_ok,
  input  logic [4:0]             raw_st_iter,
  output logic                   bw_en,
  output logic [12:0]            bw_addr,
  output logic [7:0]             bw_data,
  output logic                   done,
  output logic [7:0]             fixed,          // codewords repaired by the second pass
  output logic [11:0]            isum2,          // iterations of the second pass (sum / maximum)
  output logic [4:0]             imax2,
  output logic                   busy
);
  localparam int ND   = NUM_DATA_SC;                 // 1100
  localparam int NCW  = 2 * MAX_SYMS;
  localparam int CWB  = $clog2(NCW);
  localparam int ZAW  = $clog2(MAX_SYMS * ND);
  localparam int SW   = 24;                          // S accumulator width (|S| <= 8 symbols * 24 * 32768 < 2^23)
  localparam int EW   = 11;

  typedef enum logic [3:0] {S_IDLE, S_START, S_ACC, S_ACCD, S_W, S_WD, S_NEXT, S_SEEK, S_SEND, S_WAIT, S_FIN} st_t;
  st_t st;

  // ===================================================================== first pass capture
  (* ram_style = "block" *) logic [31:0]  zbuf [MAX_SYMS * ND];
  (* ram_style = "block" *) logic [119:0] cws  [NCW * 64];
  logic [ZAW-1:0] zw, z_ra;
  logic [31:0]    z_q;
  logic [CWB:0]   cwc, cwi;
  logic           cap_en;
  logic [NCW-1:0] failm;
  wire  [CWB:0]   ncw_tot = mode ? (CWB+1)'({nsyms, 1'b0}) : (CWB+1)'(nsyms);
  logic [CWB+5:0] c_ra;
  logic [119:0]   c_q;
  always_ff @(posedge clk) begin
    if (z_valid && cap_en) zbuf[zw] <= {z_re, z_im};
    z_q <= zbuf[z_ra];
  end
  always_ff @(posedge clk) begin
    if (col_valid && cap_en) cws[{cwc[CWB-1:0], col_idx}] <= {col_rel, col_hard};
    c_q <= cws[c_ra];
  end
  always_ff @(posedge clk) begin
    if (rst || clr) begin zw <= '0; cwc <= '0; cwi <= '0; failm <= '0; cap_en <= 1'b1; end
    else begin
      if (z_valid && cap_en) zw <= zw + 1'b1;
      if (col_valid && cap_en && col_idx == 6'd35) cwc <= cwc + 1'b1;
      if (cw_valid && cap_en) begin failm[cwi[CWB-1:0]] <= !cw_ok; cwi <= cwi + 1'b1; end
      if (st == S_START && cwc == ncw_tot) cap_en <= 1'b0;
    end
  end

  // ===================================================================== ACC: re-modulation and accumulation
  logic [7:0]     s_cnt;
  logic [10:0]    j_cnt, m_cnt;
  logic [5:0]     jf;
  logic [4:0]     js;
  logic [CWB-1:0] cwq;
  logic [5:0]     colq;
  logic [4:0]     posq;
  logic [ZAW-1:0] sbase;
  wire            fillq = (j_cnt >= 11'd1080);
  wire  [4:0]     posmax = mode ? 5'd14 : 5'd29;

  // cycle t: store address {cwq, colq} (FSM counters)   t+1: store output c_q, a_* = the position that belongs to it   t+2: Z buffer output,
  // b_* = symbol   t+3: c_* = products (registered: timing)   t+4: accumulator read data, d_* = contribution, write
  logic        a_v, a_fill, a_odd, a_first; logic [4:0] a_pos; logic [10:0] a_m; logic [ZAW-1:0] a_za;
  logic        b_v, b_first, b_used; logic [10:0] b_m; logic signed [4:0] b_xr, b_xi;
  logic        c_v, c_first, c_used; logic [10:0] c_m; logic signed [21:0] c_rr, c_ii, c_ri, c_ir; logic [EW-1:0] c_eh;
  logic        d_v, d_first, d_used; logic [10:0] d_m; logic signed [SW-1:0] d_sr, d_si; logic [EW-1:0] d_eh;

  function automatic logic signed [4:0] lev4(input logic [1:0] g);        // Gray pair -> level in quarter units
    case (g)
      2'b00:   return -5'sd12;
      2'b01:   return -5'sd4;
      2'b11:   return  5'sd4;
      default: return  5'sd12;
    endcase
  endfunction

  logic [3:0] wd4; logic [1:0] wd2; logic kn;
  always_comb begin
    logic [3:0] h4, r4, w4;
    logic [1:0] h2, r2;
    h4 = c_q[4 * int'(a_pos[3:0]) +: 4];      r4 = c_q[60 + 4 * int'(a_pos[3:0]) +: 4];
    h2 = c_q[2 * int'(a_pos) +: 2];           r2 = c_q[60 + 2 * int'(a_pos) +: 2];
    w4 = a_fill ? 4'b0101 : {h4[0], h4[1], h4[2], h4[3]};           // first coded bit = MSB of the word
    wd4 = a_odd ? {w4[2:0], w4[3]} : w4;                             // interleaver: odd positions carry the word rotated left by one bit
    wd2 = a_fill ? 2'b01 : {h2[0], h2[1]};
    kn  = a_fill ? 1'b1 : (mode ? (&r4) : (&r2));
  end

  (* ram_style = "block" *) logic [2*SW+EW-1:0] acc [2048];
  logic [2*SW+EW-1:0] acc_q;
  logic [10:0]        acc_ra;
  wire  signed [SW-1:0] aq_sr = acc_q[2*SW+EW-1 -: SW];
  wire  signed [SW-1:0] aq_si = acc_q[SW+EW-1 -: SW];
  wire  [EW-1:0]        aq_eh = acc_q[EW-1:0];
  wire  signed [IQ_W-1:0] zq_r = z_q[31:16];
  wire  signed [IQ_W-1:0] zq_i = z_q[15:0];
  (* use_dsp = "no" *) logic signed [21:0] m_rr, m_ii, m_ri, m_ir;
  always_comb begin
    m_rr = b_xr * zq_r; m_ii = b_xi * zq_i; m_ri = b_xr * zq_i; m_ir = b_xi * zq_r;
  end
  wire signed [9:0] b_e2 = 10'(b_xr) * 10'(b_xr) + 10'(b_xi) * 10'(b_xi);
  always_ff @(posedge clk) begin
    if (rst) begin b_v <= 1'b0; c_v <= 1'b0; d_v <= 1'b0; end
    else begin b_v <= a_v; c_v <= b_v; d_v <= c_v; end
    b_first <= a_first; b_used <= kn; b_m <= a_m;
    b_xr <= mode ? lev4(wd4[3:2]) : (wd2[1] ? 5'sd9 : -5'sd9);
    b_xi <= mode ? lev4(wd4[1:0]) : (wd2[0] ? 5'sd9 : -5'sd9);
    c_first <= b_first; c_used <= b_used; c_m <= b_m; c_rr <= m_rr; c_ii <= m_ii; c_ri <= m_ri; c_ir <= m_ir; c_eh <= EW'(b_e2 >> 1);
    d_first <= c_first; d_used <= c_used; d_m <= c_m;
    d_sr <= SW'(c_rr) + SW'(c_ii);
    d_si <= SW'(c_ri) - SW'(c_ir);
    d_eh <= c_eh;
    if (d_v) acc[d_m] <= {(d_first ? SW'(0) : aq_sr) + (d_used ? d_sr : SW'(0)),
                          (d_first ? SW'(0) : aq_si) + (d_used ? d_si : SW'(0)),
                          (d_first ? EW'(0) : aq_eh) + (d_used ? d_eh : EW'(0))};
    acc_q <= acc[acc_ra];
  end

  // ===================================================================== W: weights
  logic [10:0] wm;
  logic        w0_v; logic [10:0] w0_m;                       // address issued
  logic        w1_v; logic [10:0] w1_m; logic [15:0] w1_t; logic signed [SW-1:0] w1_sr, w1_si; logic [EW-1:0] w1_eh;
  logic        w2_v; logic [10:0] w2_m; logic signed [27:0] w2_nr, w2_ni; logic [26:0] w2_m1;
  logic        w3_v; logic [10:0] w3_m; logic signed [27:0] w3_nr, w3_ni; logic [26:0] w3_m1; logic [4:0] w3_p; logic w3_z;
  logic        w4_v; logic [10:0] w4_m; logic signed [27:0] w4_nr, w4_ni; logic [11:0] w4_mant; logic [4:0] w4_sh; logic w4_z;
  logic        w5_v; logic [10:0] w5_m; logic signed [27:0] w5_nr, w5_ni; logic [15:0] w5_r; logic [4:0] w5_sh; logic w5_z;
  logic        w6_v; logic [10:0] w6_m; logic signed [44:0] w6_pr, w6_pi; logic [4:0] w6_sh; logic w6_z;
  logic        w7_v; logic [10:0] w7_m; logic signed [47:0] w7_tr, w7_ti; logic [4:0] w7_sh; logic w7_z;
  logic        w8_v; logic [10:0] w8_m; logic signed [47:0] w8_ur, w8_ui; logic w8_z;
  logic        g_v;  logic [10:0] g_m;  logic signed [IQ_W-1:0] g_r, g_i;

  (* rom_style = "block" *) logic [15:0] rrom [2048];           // round(2^27 / mant), mant = 2048 .. 4095, limited to 16 bit
  initial begin
    for (int i = 0; i < 2048; i++) begin
      int r;
      r = ((1 << 28) + (2048 + i)) / (2 * (2048 + i));
      rrom[i] = (r > 65535) ? 16'hFFFF : 16'(r);
    end
  end

  logic [4:0] lead;
  always_comb begin
    lead = '0;
    for (int b = 0; b < 27; b++) if (w2_m1[b]) lead = 5'(b);
  end
  function automatic logic signed [IQ_W-1:0] sat_g(input logic signed [47:0] v);
    return (v > 48'sd32767) ? 16'sd32767 : (v < -48'sd32767) ? -16'sd32767 : v[15:0];
  endfunction
  wire [15:0] t_rd = prm_rd[28:13];
  always_ff @(posedge clk) begin
    if (rst) begin w0_v <= 1'b0; w1_v <= 1'b0; w2_v <= 1'b0; w3_v <= 1'b0; w4_v <= 1'b0; w5_v <= 1'b0; w6_v <= 1'b0; w7_v <= 1'b0; w8_v <= 1'b0; g_v <= 1'b0; end
    else begin
      w0_v <= (st == S_W); w1_v <= w0_v; w2_v <= w1_v; w3_v <= w2_v; w4_v <= w3_v; w5_v <= w4_v; w6_v <= w5_v; w7_v <= w6_v; w8_v <= w7_v; g_v <= w8_v;
    end
    w0_m <= wm;
    // RAM outputs (accumulators, T)
    w1_m <= w0_m; w1_t <= t_rd; w1_sr <= aq_sr; w1_si <= aq_si; w1_eh <= aq_eh;
    // N1, M1
    w2_m <= w1_m;
    w2_nr <= 28'($signed({1'b0, w1_t})) * 28'sd216 + (28'(w1_sr) <<< 2);
    w2_ni <= 28'(w1_si) <<< 2;
    w2_m1 <= 27'(w1_t) * 27'(EW'(W0H) + w1_eh);
    // leading one of M1
    w3_m <= w2_m; w3_nr <= w2_nr; w3_ni <= w2_ni; w3_m1 <= w2_m1; w3_p <= lead; w3_z <= (w2_m1 == 27'd0);
    // mantissa (12 bit, MSB set), shift = 15 + e = 4 + position of the leading one
    w4_m <= w3_m; w4_nr <= w3_nr; w4_ni <= w3_ni; w4_z <= w3_z;
    w4_mant <= (w3_p >= 5'd11) ? 12'(w3_m1 >> (w3_p - 5'd11)) : 12'(w3_m1 << (5'd11 - w3_p));
    w4_sh <= w3_p + 5'd4;
    // reciprocal
    w5_m <= w4_m; w5_nr <= w4_nr; w5_ni <= w4_ni; w5_z <= w4_z; w5_sh <= w4_sh; w5_r <= rrom[w4_mant[10:0]];
    // products
    w6_m <= w5_m; w6_z <= w5_z; w6_sh <= w5_sh;
    w6_pr <= w5_nr * $signed({1'b0, w5_r});
    w6_pi <= w5_ni * $signed({1'b0, w5_r});
    // * 3, rounding
    w7_m <= w6_m; w7_z <= w6_z; w7_sh <= w6_sh;
    w7_tr <= 48'(w6_pr) + (48'(w6_pr) <<< 1) + (48'sd1 <<< (w6_sh - 5'd1));
    w7_ti <= 48'(w6_pi) + (48'(w6_pi) <<< 1) + (48'sd1 <<< (w6_sh - 5'd1));
    // shift
    w8_m <= w7_m; w8_z <= w7_z;
    w8_ur <= w7_tr >>> w7_sh; w8_ui <= w7_ti >>> w7_sh;
    // G
    g_m <= w8_m;
    g_r <= w8_z ? 16'sd12288 : sat_g(w8_ur);
    g_i <= w8_z ? 16'sd0     : sat_g(w8_ui);
  end

  logic        wc_v; logic [10:0] wc_a; logic [39:0] wc_w;
  phy_w_core u_wc (.clk, .rst, .in_valid(g_v), .in_addr(g_m), .in_re(g_r), .in_im(g_i), .out_valid(wc_v), .out_addr(wc_a), .out_w(wc_w));

  (* ram_style = "block" *) logic [39:0] w2ram [2048];
  logic [39:0] eq_wd; logic [10:0] eq_wa;
  always_ff @(posedge clk) begin
    if (wc_v) w2ram[wc_a] <= wc_w;
    eq_wd <= w2ram[eq_wa];
  end

  // ===================================================================== P2: replay through the correction equalizer
  logic [7:0]     s2;
  logic [10:0]    pm;
  logic [ZAW-1:0] zbase2;
  logic [12:0]    bbase, ks_pos, ks_tgt;
  logic [14:0]    ks_l;
  logic [1:0]     fm, stc;
  logic           e_v, e_f, e_l;
  wire  [1:0]     fm_w = mode ? {failm[{s2[CWB-2:0], 1'b1}], failm[{s2[CWB-2:0], 1'b0}]} : {1'b0, failm[s2[CWB-1:0]]};
  phy_equalizer u_eq2 (
    .clk, .rst, .in_valid(e_v), .in_first(e_f), .in_last(e_l), .in_re(zq_r), .in_im(zq_i), .rd_addr(eq_wa), .rd_data(eq_wd),
    .out_valid, .out_first, .out_last, .out_re, .out_im
  );

  // keystream of the additive scrambler (python/scrambler_ref.py), one byte per step
  logic [7:0]  ks_b; logic [14:0] ks_n;
  always_comb begin
    logic fb;
    ks_n = ks_l; ks_b = '0;
    for (int i = 7; i >= 0; i--) begin fb = ks_n[14] ^ ks_n[13]; ks_b[i] = fb; ks_n = {ks_n[13:0], fb}; end
  end

  assign busy    = (st != S_IDLE);
  assign prm_sel = (st == S_W) || (st == S_WD);
  assign prm_ra  = wm;
  assign acc_ra  = (st == S_ACC || st == S_ACCD) ? c_m : wm;
  assign z_ra    = (st == S_SEND) ? (zbase2 + ZAW'(pm)) : a_za;
  assign c_ra    = {cwq, colq};
  assign p2_skip = mode ? ~fm : 2'b00;

  always_ff @(posedge clk) begin
    done <= 1'b0; bw_en <= 1'b0; a_v <= 1'b0; e_v <= 1'b0;
    if (rst) begin
      st <= S_IDLE; p2 <= 1'b0; fixed <= '0; isum2 <= '0; imax2 <= '0; fm <= '0; stc <= '0;
      s_cnt <= '0; j_cnt <= '0; m_cnt <= '0; jf <= '0; js <= '0; cwq <= '0; colq <= '0; posq <= '0; sbase <= '0; wm <= '0;
      s2 <= '0; pm <= '0; zbase2 <= '0; bbase <= '0; ks_pos <= '0; ks_tgt <= '0; ks_l <= SCR_SEED;
    end else begin
      // second pass: decoder bytes -> packet buffer, statistics
      if (raw_valid && p2) begin
        bw_en <= 1'b1; bw_addr <= ks_pos; bw_data <= raw_data ^ ks_b; ks_l <= ks_n; ks_pos <= ks_pos + 1'b1;
      end
      if (raw_st_valid && p2) begin
        stc <= stc + 1'b1; isum2 <= isum2 + 12'(raw_st_iter);
        if (raw_st_ok) fixed <= fixed + 1'b1;
        if (raw_st_iter > imax2) imax2 <= raw_st_iter;
      end
      case (st)
        S_IDLE: if (start) begin
          st <= S_START; fixed <= '0; isum2 <= '0; imax2 <= '0;
        end
        S_START: if (!cap_en) begin                        // all columns of the first pass are stored
          st <= S_ACC; s_cnt <= '0; j_cnt <= '0; m_cnt <= '0; jf <= '0; js <= '0; cwq <= '0; colq <= '0; posq <= '0; sbase <= '0;
        end
        S_ACC: begin
          a_v <= 1'b1; a_fill <= fillq; a_odd <= js[0]; a_first <= (s_cnt == 8'd0); a_pos <= posq; a_m <= m_cnt; a_za <= sbase + ZAW'(m_cnt);
          // coded word position inside the codeword store
          if (!fillq) begin
            if (posq == posmax) begin
              posq <= '0;
              if (colq == 6'd35) begin colq <= '0; cwq <= cwq + 1'b1; end else colq <= colq + 1'b1;
            end else posq <= posq + 1'b1;
          end
          // data bin of the word
          if (jf == 6'(IL_ROWS - 1)) begin jf <= '0; js <= js + 1'b1; m_cnt <= 11'(js) + 11'd1; end
          else begin jf <= jf + 1'b1; m_cnt <= m_cnt + 11'(IL_COLS); end
          if (j_cnt == 11'(ND - 1)) begin
            j_cnt <= '0; jf <= '0; js <= '0; m_cnt <= '0; posq <= '0; colq <= '0; sbase <= sbase + ZAW'(ND);
            if (s_cnt + 8'd1 == nsyms) begin st <= S_ACCD; wm <= '0; end
            else s_cnt <= s_cnt + 1'b1;
          end else j_cnt <= j_cnt + 1'b1;
        end
        S_ACCD: begin                                       // drain the accumulation pipeline
          wm <= wm + 1'b1;
          if (wm == 11'd7) begin st <= S_W; wm <= '0; end
        end
        S_W: begin
          if (wm == 11'(ND - 1)) st <= S_WD; else wm <= wm + 1'b1;
        end
        S_WD: if (wc_v && wc_a == 11'(ND - 1)) begin
          st <= S_NEXT; p2 <= 1'b1; s2 <= '0; zbase2 <= '0; bbase <= '0; ks_pos <= '0; ks_l <= SCR_SEED;
        end
        S_NEXT: begin
          stc <= '0; fm <= fm_w; pm <= '0;
          if (s2 == nsyms) st <= S_FIN;
          else if (fm_w == 2'b00) begin
            s2 <= s2 + 1'b1; zbase2 <= zbase2 + ZAW'(ND); bbase <= bbase + (mode ? 13'd450 : 13'd135);
          end else begin
            ks_tgt <= bbase + ((mode && !fm_w[0]) ? 13'd225 : 13'd0);
            st <= S_SEEK;
          end
        end
        S_SEEK: begin
          if (ks_pos == ks_tgt) st <= S_SEND;
          else begin ks_l <= ks_n; ks_pos <= ks_pos + 1'b1; end
        end
        S_SEND: begin
          e_v <= 1'b1; e_f <= (pm == 11'd0); e_l <= (pm == 11'(ND - 1));
          if (pm == 11'(ND - 1)) st <= S_WAIT; else pm <= pm + 1'b1;
        end
        S_WAIT: if (stc == {1'b0, fm[0]} + {1'b0, fm[1]}) begin
          s2 <= s2 + 1'b1; zbase2 <= zbase2 + ZAW'(ND); bbase <= bbase + (mode ? 13'd450 : 13'd135);
          st <= S_NEXT;
        end
        S_FIN: begin done <= 1'b1; p2 <= 1'b0; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
