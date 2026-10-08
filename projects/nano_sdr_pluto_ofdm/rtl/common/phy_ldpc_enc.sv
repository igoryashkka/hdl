// Module : phy_ldpc_enc   systematic QC-LDPC encoder (N = 2160, Z = 60), two codes on one datapath (cfg_mode):
//   cfg_mode = 0: MAX RANGE, rate 1/2 (K = 1080, 135 bytes per codeword, QPSK: 2 bit words, 1 codeword per OFDM symbol)
//   cfg_mode = 1: MAX RATE,  rate 5/6 (K = 1800, 225 bytes per codeword, 16-QAM: 4 bit words, 2 codewords per OFDM symbol)
//   Input  : bytes (MSB first = lowest information bit index), valid/ready.
//   Output : the codeword [info | parity] as words (QPSK: out_data[1:0] = {I bit, Q bit}, 1080 words; 16-QAM: 4 bit nibble, first bit = MSB,
//            540 nibbles), valid/ready; after the last codeword of a symbol 20 filler words (alternating 0 / 1 bits) complete the 1100
//            words of an OFDM symbol (4400 bits for 16-QAM, 2200 bits for QPSK).
// Algorithm (golden python/ldpc_ref.py::encode): lambda_i = sum_j rot(u_j, s_ij) over the information entries of block row i
// (one entry per cycle: column mux + 60 bit barrel rotator), p0 = sum_i lambda_i, p1 = lambda_0 ^ rot(p0, a),
// p_{i+1} = lambda_i ^ p_i (^ p0 for i = LMID).  One codeword at a time.
module phy_ldpc_enc
  import phy_ldpc_pkg::*;
#(
  parameter int FILL_WORDS = 20
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       cfg_mode,                  // static while a packet is in flight
  input  logic       in_valid,
  output logic       in_ready,
  input  logic [7:0] in_data,
  output logic       out_valid,
  input  logic       out_ready,
  output logic [3:0] out_data
);
  localparam int Z  = LZ;
  localparam int NBYTES_MAX = LK / 8;           // 225

  typedef enum logic [2:0] {E_LOAD, E_LAM, E_DRAIN, E_PAR, E_PACK, E_OUT, E_FILL} st_t;
  st_t st;

  wire        qpsk   = ~cfg_mode;
  wire  [1:0] cs     = {1'b0, cfg_mode};
  wire  [4:0] mb_c   = 5'(lmb(int'(cfg_mode)));
  wire  [7:0] nbytes = 8'(lkb(int'(cfg_mode)) * Z / 8);      // 135 / 225
  wire  [11:0] nwords = qpsk ? 12'd1080 : 12'd540;

  logic [LK-1:0]   u;                        // information bits, first bit at the MSB (a code with fewer columns ends up in the low bits)
  logic [Z-1:0]    lam [LMB];
  logic [Z-1:0]    par [LMB];
  logic [7:0]      bcnt;
  logic [4:0]      row;
  logic [4:0]      ent;
  logic [11:0]     ncnt;
  logic [1:0]      cwc;                      // codeword counter inside the symbol
  logic [4:0]      fcnt;
  logic [4:0]      pstep;

  logic         iss, clr_lam;
  assign in_ready = (st == E_LOAD);
  assign iss      = (st == E_LAM);
  assign clr_lam  = (st == E_LOAD);

  // column vector (bit r = information bit 60 c + r) and rotation out[r] = in[(r + s) % Z]: 4-stage pipeline (ROM, column mux, rotate, XOR)
  logic [Z-1:0] ucol [LKB];                  // constant slices of the information register (column mux, no variable shifter)
  always_comb for (int c = 0; c < LKB; c++) for (int r = 0; r < Z; r++) ucol[c][r] = u[LK - 1 - 60 * c - r];
  logic         q0_v, q1_v, q2_v;
  logic [5:0]   q0_col, q0_sh, q1_sh;
  logic [4:0]   q0_row, q1_row, q2_row;
  logic [Z-1:0] q1_cv, q2_rv;
  logic [2:0]   dcnt;
  always_ff @(posedge clk) begin
    q0_v <= iss; q0_col <= enc_col(int'(cfg_mode), int'(row), int'(ent)); q0_sh <= enc_sh(int'(cfg_mode), int'(row), int'(ent)); q0_row <= row;
    q1_v <= q0_v; q1_cv <= ucol[q0_col]; q1_sh <= q0_sh; q1_row <= q0_row;
    q2_v <= q1_v; q2_row <= q1_row;
    begin
      logic [Z-1:0] t;
      t = q1_cv;
      for (int s = 0; s < 6; s++) begin
        logic [Z-1:0] w;
        for (int r = 0; r < Z; r++) w[r] = q1_sh[s] ? t[(r + (1 << s)) % Z] : t[r];
        t = w;
      end
      q2_rv <= t;
    end
    if (rst) begin q0_v <= 1'b0; q1_v <= 1'b0; q2_v <= 1'b0; end
  end
  // XOR stage (separate process: lam is also cleared in E_LOAD)
  always_ff @(posedge clk) begin
    if (q2_v) lam[q2_row] <= lam[q2_row] ^ q2_rv;
    else if (clr_lam) for (int i = 0; i < LMB; i++) lam[i] <= '0;
  end

  function automatic logic [Z-1:0] rotv(input logic [Z-1:0] x, input int sh);
    logic [Z-1:0] y;
    for (int r = 0; r < Z; r++) y[r] = x[(r + sh) % Z];
    return y;
  endfunction

  logic [LN-1:0] cwr;                        // codeword shift register, first transmitted bit at the MSB
  wire  [3:0]    nib = qpsk ? {2'b00, cwr[LN-1 -: 2]} : cwr[LN-1 -: 4];

  assign out_valid = (st == E_OUT) || (st == E_FILL);
  assign out_data  = (st == E_FILL) ? (qpsk ? 4'h1 : 4'h5) : nib;

  wire [1:0] cw_per_sym_m1 = qpsk ? 2'd0 : 2'd1;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= E_LOAD; bcnt <= '0; row <= '0; ent <= '0; ncnt <= '0; cwc <= '0; fcnt <= '0; pstep <= '0;
    end else begin
      case (st)
        E_LOAD: if (in_valid) begin
          u <= {u[LK-9:0], in_data};
          if (bcnt == nbytes - 8'd1) begin
            bcnt <= '0; st <= E_LAM; row <= '0; ent <= '0;
          end else bcnt <= bcnt + 1'b1;
        end
        E_LAM: begin
          if (5'(ent) + 5'd1 == 5'(enc_n(int'(cfg_mode), int'(row)))) begin
            ent <= '0;
            if (row == mb_c - 5'd1) begin st <= E_DRAIN; dcnt <= 3'd4; end
            else row <= row + 1'b1;
          end else ent <= ent + 1'b1;
        end
        E_DRAIN: begin
          if (dcnt == 3'd0) begin st <= E_PAR; pstep <= '0; end else dcnt <= dcnt - 1'b1;
        end
        E_PAR: begin
          // pstep 0: p0 ; 1: p1 ; 2..mb-1: p2..p_{mb-1} (one per cycle)
          case (pstep)
            5'd0: begin
              logic [Z-1:0] a;
              a = '0;
              for (int i = 0; i < LMB; i++) a = a ^ lam[i];          // unused rows stay zero
              par[0] <= a; pstep <= 5'd1;
            end
            5'd1: begin par[1] <= lam[0] ^ (cfg_mode ? rotv(par[0], lpa(1)) : rotv(par[0], lpa(0))); pstep <= 5'd2; end   // two constant rotations, no variable modulo
            default: begin
              // p_{i+1} = lam_i ^ p_i (^ p0 when i == LMID), i = pstep - 1
              par[pstep] <= lam[pstep - 1] ^ par[pstep - 1] ^ ((int'(pstep) - 1 == lmid(int'(cfg_mode))) ? par[0] : '0);
              if (pstep == mb_c - 5'd1) begin st <= E_PACK; ncnt <= '0; end
              else pstep <= pstep + 1'b1;
            end
          endcase
        end
        E_PACK: begin
          if (qpsk) begin                    // K = 1080: info in u[1079:0], parity 18 x 60
            cwr[LN-1 -: 1080] <= u[1079:0];
            for (int i = 0; i < 18; i++) for (int r = 0; r < Z; r++) cwr[LN - 1080 - 1 - 60 * i - r] <= par[i][r];
          end else begin                     // K = 1800: info 30 x 60, parity 6 x 60
            cwr[LN-1 -: LK] <= u;
            for (int i = 0; i < 6; i++) for (int r = 0; r < Z; r++) cwr[LN - LK - 1 - 60 * i - r] <= par[i][r];
          end
          st <= E_OUT;
        end
        E_OUT: if (out_ready) begin
          cwr <= qpsk ? {cwr[LN-3:0], 2'b00} : {cwr[LN-5:0], 4'h0};
          if (ncnt == nwords - 12'd1) begin
            ncnt <= '0;
            if (cwc == cw_per_sym_m1) begin
              cwc <= '0;
              if (FILL_WORDS > 0) begin st <= E_FILL; fcnt <= '0; end else st <= E_LOAD;
            end else begin cwc <= cwc + 1'b1; st <= E_LOAD; end
          end else ncnt <= ncnt + 1'b1;
        end
        E_FILL: if (out_ready) begin
          if (fcnt == 5'(FILL_WORDS - 1)) st <= E_LOAD; else fcnt <= fcnt + 1'b1;
        end
        default: st <= E_LOAD;
      endcase
    end
  end
endmodule
