"""Fixed-point model of the PHY v2 soft receiver back-end (golden for phy_noise_est, phy_mmse_post, phy_llr_demap).

Chain (all integer arithmetic):
  LTS FFT output (16 bit) --chest_one--> ZF weights (mr, mi, E) and log code of |G|^2 per active bin
  guard-bin energy of the LTS FFT output --> noise log code (nu, in |G|^2 units)
  post engine (per bin, one pass after the LTS): d = lg|G|^2 - lg nu ->  mu (MMSE shrink), threshold T, LLR gain (gm, e)
        MMSE:  w <- w * mu ;  LLR = (L * gm) >> sh  with L0 = -x, L1 = |x| - T, T = 2*mu*QAM_UNIT, gain ~ (|G|^2 + nu)/nu
        ZF  :  w unchanged ;  T = 2*QAM_UNIT, gain ~ |G|^2 / nu
  data bins -> equalizer (rx_fixed_ref.equalize) -> common phase (rx_fixed_ref.cpe_track) -> soft demapper -> 6 bit LLRs.
Log code: 1/LGF octave steps, code = p*LGF + LGT[mantissa], p = floor(log2 x).
"""
from __future__ import annotations

import math

import numpy as np

import ofdm_ref
import rx_fixed_ref as rf
from phy_params import FFT_SIZE, NUM_ACTIVE_SC, PILOT_AMP, QAM_UNIT

LGF = 32                    # log2 fractional steps per octave
LGM = 5                     # mantissa bits used for the log lookup (32 entries)
LGT = np.array([int(round(LGF * math.log2(1.0 + (i + 0.5) / (1 << LGM)))) for i in range(1 << LGM)], dtype=np.int64)
GUARD = np.arange(700, 1349)            # unused bins far from the band edge (|k| >= 700): noise only
N_GUARD = len(GUARD)
CNU = int(round(LGF * math.log2(0.9 / N_GUARD)))      # nu = 0.9 * mean guard energy (A^2 / P_data = 0.9)
D_MIN, D_MAX = -8 * LGF, 31 * LGF       # clamp of the log ratio d = lg m - lg nu
D_STEP = 2                              # table index resolution: d >> 1 (1/16 octave)
SH_C = 18                               # LLR scale: sh = SH_C - e   (calibrated with phy2_fixed_test.py: PER 0 from 15.5 dB AWGN / 18 dB 2-path)
LLR_MAX = 31


def lgcode(x: int) -> int:
    """log2(x) * LGF, x > 0 integer (0 -> very small value)."""
    x = int(x)
    if x <= 0:
        return -1000
    p = x.bit_length() - 1
    fr = ((x << LGM) >> p) & ((1 << LGM) - 1) if p >= 0 else 0
    return p * LGF + int(LGT[fr])


def _mu_table():
    n = (D_MAX - D_MIN) // D_STEP + 1
    d = (D_MIN + np.arange(n) * D_STEP) / LGF
    mu = 1.0 / (1.0 + 2.0 ** (-d))
    gm = np.log2(1.0 + 2.0 ** d) * LGF                    # MMSE gain log (g = (m+nu)/nu)
    gz = d * LGF
    return (np.minimum(65535, np.rint(mu * 65536)).astype(np.int64), np.rint(gm).astype(np.int64), np.rint(gz).astype(np.int64))


MU_T, GL_MMSE_T, GL_ZF_T = _mu_table()
EXP2_T = np.array([int(round(32 * 2.0 ** (i / LGF))) for i in range(LGF)], dtype=np.int64)   # 32..63 for the fractional log part


def _idx(d: int) -> int:
    d = max(D_MIN, min(D_MAX, int(d)))
    return (d - D_MIN) // D_STEP


# ------------------------------------------------------------------ per-bin side information from the LTS
def chest_lg(yr, yi):
    """lg(|G|^2) code per active bin (G = Y*sigma, saturated like chest_one)."""
    return chest_lg_sum(yr, yi)[0]


def chest_lg_sum(yr, yi):
    """(lg codes, sum of |G|^2 over the bins)."""
    sg = rf.lts_sign()
    out, tot = [], 0
    for a, b, s in zip(yr, yi, sg):
        gr, gi = max(-32767, min(32767, int(a) * int(s))), max(-32767, min(32767, int(b) * int(s)))
        m = gr * gr + gi * gi
        tot += m
        out.append(lgcode(m))
    return np.array(out, dtype=np.int64), tot


def noise_code(yfull_r, yfull_i) -> int:
    s = int(np.sum(np.asarray(yfull_r)[GUARD].astype(np.int64) ** 2 + np.asarray(yfull_i)[GUARD].astype(np.int64) ** 2))
    return lgcode(s) + CNU, s


LG_NSC = int(round(LGF * math.log2(NUM_ACTIVE_SC)))      # log code of the number of active bins (mean of the |G|^2 sum)
BAD_D = 106                                              # default "bad subcarrier" threshold: 10 dB = 3.32 octaves * 32


def quality_codes(lgm, lgnu, sig_sum, bad_thr=BAD_D):
    """(snr_avg_code, snr_min_code, bad_count): per-bin SNR code d = lg|G|^2 - lg nu; the average from the linear |G|^2 sum.
    Codes are in 1/32 octave: dB = code * 3.0103 / 32."""
    d = np.clip(np.asarray(lgm, np.int64) - int(lgnu), D_MIN, D_MAX)
    snr_avg = lgcode(int(sig_sum)) - LG_NSC - int(lgnu)
    return int(snr_avg), int(d.min()), int((d < bad_thr).sum())


def post_engine(mr, mi, E, lgm, lgnu, mmse: bool):
    """Returns (mr2, mi2, T (per bin), gm (32..63), e (exponent of the gain))."""
    n = len(mr)
    mr2, mi2 = np.array(mr, np.int64), np.array(mi, np.int64)
    T = np.zeros(n, np.int64)
    gm = np.zeros(n, np.int64)
    ge = np.zeros(n, np.int64)
    for k in range(n):
        d = int(lgm[k]) - int(lgnu)
        i = _idx(d)
        if mmse:
            mu = int(MU_T[i])
            mr2[k] = (int(mr[k]) * mu + 32768) >> 16
            mi2[k] = (int(mi[k]) * mu + 32768) >> 16
            T[k] = (2 * QAM_UNIT * mu + 32768) >> 16
            gl = int(GL_MMSE_T[i])
        else:
            T[k] = 2 * QAM_UNIT
            gl = int(GL_ZF_T[i])
        ge[k] = gl >> 5                       # floor(gl / LGF)  (LGF = 32)
        gm[k] = EXP2_T[gl & (LGF - 1)]
    return mr2, mi2, T, gm, ge


def demap_soft(xr, xi, T, gm, ge):
    """xr, xi: 1100 data-bin values (after common-phase correction); returns (1100, 4) LLRs [I b0, I b1, Q b0, Q b1], 6 bit signed."""
    out = np.zeros((len(xr), 4), np.int64)
    for k in range(len(xr)):
        sh = SH_C - int(ge[k])
        for ax, x in enumerate((int(xr[k]), int(xi[k]))):
            for b, lv in enumerate((-x, abs(x) - int(T[k]))):
                p = lv * int(gm[k])
                v = (p << -sh) if sh <= 0 else ((p + (1 << (sh - 1))) >> sh)
                out[k, 2 * ax + b] = max(-LLR_MAX, min(LLR_MAX, v))
    return out


def receive_symbols(y_lts_full, y_data_full, mmse=True):
    """y_*_full: integer (re, im) arrays of 2048 bins (rx_fft outputs). Returns (llr (nsym, 1100, 4), diagnostics)."""
    yr, yi = rf.select_active(*y_lts_full)
    mr, mi, E = rf.chest(yr, yi)
    lgm, sig_sum = chest_lg_sum(yr, yi)
    lgnu, S = noise_code(*y_lts_full)
    mr2, mi2, T, gm, ge = post_engine(mr, mi, E, lgm, lgnu, mmse)
    ds = rf.DATA_S
    llrs = []
    angs = []
    eqs = []
    for yfr, yfi in y_data_full:
        dr, di = rf.select_active(yfr, yfi)
        xr, xi = rf.equalize(dr, di, mr2, mi2, E)
        xr, xi, ang = rf.cpe_track(xr, xi)
        angs.append(ang)
        eqs.append((xr[ds].copy(), xi[ds].copy()))
        llrs.append(demap_soft(xr[ds], xi[ds], T[ds], gm[ds], ge[ds]))
    diag = {"lgm": lgm, "lgnu": lgnu, "noise_sum": S, "sig_sum": sig_sum, "quality": quality_codes(lgm, lgnu, sig_sum), "angles": angs, "eq": eqs, "T": T[ds], "gm": gm[ds], "ge": ge[ds]}
    return np.array(llrs), diag


def decode_llr(llr, nsym, nbytes, iters=10):
    """llr (nsym, 1100, 4) ints -> payload bytes (descrambled), iterations per codeword, converged flags (fixed-point LDPC)."""
    import phy2_ref as P
    import ldpc_fixed_ref as lf
    import scrambler_ref
    deint = P.deinterleave_llr(np.asarray(llr, dtype=float))
    cw = np.rint(deint[:, :P.CODED_BITS]).astype(np.int64).reshape(nsym * P.CW_PER_SYM, P.CODE_N)
    hard, its, done = lf.decode(np.clip(cw, -31, 31), iters)
    raw = scrambler_ref.scramble([int(b) for b in np.packbits(hard[:, :P.CODE_K].reshape(-1))])
    return bytes(raw[:nbytes]), its, done
