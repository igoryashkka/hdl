// Module : phy_ldpc_enc   systematic QC-LDPC encoder (R = 5/6, N = 2160, K = 1800, Z = 60) with nibble output.
//   Input  : bytes (225 per codeword, MSB first = lowest information bit index), valid/ready.
//   Output : the codeword [info | parity] as 540 nibbles (first bit = MSB), valid/ready; after every CW_PER_SYM-th codeword
//            FILL_NIBBLES filler nibbles (0x5 = bits 0,1,0,1) complete the 4400 bits of an OFDM symbol (1100 nibbles).
// Algorithm (golden python/ldpc_ref.py::encode): lambda_i = sum_j rot(u_j, s_ij) over the information entries of block row i
// (90 entries, one per cycle: column mux + 60 bit barrel rotator), p0 = sum_i lambda_i, p1 = lambda_0 ^ rot(p0, a),
// p_{i+1} = lambda_i ^ p_i (^ p0 for i = LMID).  One codeword at a time: ~225 + 100 + 540 cycles.
module phy_ldpc_enc
  import phy_ldpc_pkg::*;
#(
  parameter int CW_PER_SYM   = 2,
  parameter int FILL_NIBBLES = 20
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       in_valid,
  output logic       in_ready,
  input  logic [7:0] in_data,
  output logic       out_valid,
  input  logic       out_ready,
  output logic [3:0] out_data
);
  localparam int Z  = LZ;
  localparam int NBYTES = LK / 8;           // 225
  localparam int NNIB   = LN / 4;           // 540

  typedef enum logic [2:0] {E_LOAD, E_LAM, E_DRAIN, E_PAR, E_PACK, E_OUT, E_FILL} st_t;
  st_t st;

  logic [LK-1:0]   u;                        // information bits, first bit at the MSB
  logic [Z-1:0]    lam [LMB];
  logic [Z-1:0]    par [LMB];
  logic [7:0]      bcnt;
  logic [2:0]      row;
  logic [4:0]      ent;
  logic [11:0]     ncnt;
  logic [1:0]      cwc;                      // codeword counter inside the symbol
  logic [4:0]      fcnt;
  logic [2:0]      pstep;

  logic         iss, clr_lam;
  assign in_ready = (st == E_LOAD);
  assign iss      = (st == E_LAM);
  assign clr_lam  = (st == E_LOAD);

  // column vector (bit r = information bit 60 c + r) and rotation out[r] = in[(r + s) % Z]: 4-stage pipeline (ROM, column mux, rotate, XOR)
  logic [Z-1:0] ucol [LKB];                  // constant slices of the information register (column mux, no variable shifter)
  always_comb for (int c = 0; c < LKB; c++) for (int r = 0; r < Z; r++) ucol[c][r] = u[LK - 1 - 60 * c - r];
  logic         q0_v, q1_v, q2_v;
  logic [5:0]   q0_col, q0_sh, q1_sh;
  logic [2:0]   q0_row, q1_row, q2_row;
  logic [Z-1:0] q1_cv, q2_rv;
  logic [2:0]   dcnt;
  always_ff @(posedge clk) begin
    q0_v <= iss; q0_col <= enc_col(int'(row), int'(ent)); q0_sh <= enc_sh(int'(row), int'(ent)); q0_row <= row;
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
  wire  [3:0]    nib = cwr[LN-1 -: 4];

  assign out_valid = (st == E_OUT) || (st == E_FILL);
  assign out_data  = (st == E_FILL) ? 4'h5 : nib;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= E_LOAD; bcnt <= '0; row <= '0; ent <= '0; ncnt <= '0; cwc <= '0; fcnt <= '0; pstep <= '0;
    end else begin
      case (st)
        E_LOAD: if (in_valid) begin
          u <= {u[LK-9:0], in_data};
          if (bcnt == 8'(NBYTES - 1)) begin
            bcnt <= '0; st <= E_LAM; row <= '0; ent <= '0;
          end else bcnt <= bcnt + 1'b1;
        end
        E_LAM: begin
          if (5'(ent) + 5'd1 == 5'(enc_n(int'(row)))) begin
            ent <= '0;
            if (row == 3'(LMB - 1)) begin st <= E_DRAIN; dcnt <= 3'd4; end
            else row <= row + 1'b1;
          end else ent <= ent + 1'b1;
        end
        E_DRAIN: begin
          if (dcnt == 3'd0) begin st <= E_PAR; pstep <= '0; end else dcnt <= dcnt - 1'b1;
        end
        E_PAR: begin
          // pstep 0: p0 ; 1: p1 ; 2..5: p2..p5 (one per cycle)
          case (pstep)
            3'd0: begin
              logic [Z-1:0] a;
              a = lam[0] ^ lam[1] ^ lam[2] ^ lam[3] ^ lam[4] ^ lam[5];
              par[0] <= a; pstep <= 3'd1;
            end
            3'd1: begin par[1] <= lam[0] ^ rotv(par[0], LPA); pstep <= 3'd2; end
            default: begin
              // p_{i+1} = lam_i ^ p_i (^ p0 when i == LMID), i = pstep - 1
              par[pstep] <= lam[pstep - 1] ^ par[pstep - 1] ^ ((int'(pstep) - 1 == LMID) ? par[0] : '0);
              if (pstep == 3'd5) begin st <= E_PACK; ncnt <= '0; end
              else pstep <= pstep + 1'b1;
            end
          endcase
        end
        E_PACK: begin
          cwr[LN-1 -: LK] <= u;
          for (int i = 0; i < LMB; i++) for (int r = 0; r < Z; r++) cwr[LN - LK - 1 - 60 * i - r] <= par[i][r];
          st <= E_OUT;
        end
        E_OUT: if (out_ready) begin
          cwr <= {cwr[LN-5:0], 4'h0};
          if (ncnt == 12'(NNIB - 1)) begin
            ncnt <= '0;
            if (cwc == 2'(CW_PER_SYM - 1)) begin
              cwc <= '0;
              if (FILL_NIBBLES > 0) begin st <= E_FILL; fcnt <= '0; end else st <= E_LOAD;
            end else begin cwc <= cwc + 1'b1; st <= E_LOAD; end
          end else ncnt <= ncnt + 1'b1;
        end
        E_FILL: if (out_ready) begin
          if (fcnt == 5'(FILL_NIBBLES - 1)) st <= E_LOAD; else fcnt <= fcnt + 1'b1;
        end
        default: st <= E_LOAD;
      endcase
    end
  end
endmodule
