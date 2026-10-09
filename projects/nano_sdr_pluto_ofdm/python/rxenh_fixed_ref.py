"""Fixed-point (bit-exact) models of the RX enhancements of ТЗ 004, on top of phy2_fixed_ref (baseline, unchanged).

Patch A  uncertainty-aware soft LLR (16-QAM): the channel-estimate error multiplies the transmitted symbol, so the noise of a hypothesis grows
         with its energy. Max-log LLRs keep the per-bin gain of the baseline and get region-dependent slopes:
             bit 1 (inner / outer ring):  L1 = ((|x| - T) * UA_C_MID) >> 6
             bit 0 (sign):                L0 = -x                                   for |x| <= T
                                          L0 = -sgn(x) * (T + (((|x| - T) * UA_C_OUT) >> 6))   for |x| >  T
         UA_C_MID = 57, UA_C_OUT = 51 (= 64 * (1 + 6k) / (1 + 10k), 64 * (1 + 6k) / (1 + 14k) with k = u^2 / (A^2 N_eff), N_eff = 3 smoothing bins).
         QPSK: every hypothesis has the same energy, the term is a common factor of all LLRs and is not applied (golden for phy_llr_demap, ua = 1).

Patch B  one code-aided pass (golden for phy_ca_refine + the second pass of phy_rx_top). Runs only if at least one codeword did not converge.
         Works in the equalised, phase-tracked domain z (tracker output of the data bins, still carrying the MMSE bias mu = T / 8192):
           known symbols  x^: re-modulated decoder output, in quarter QAM_UNIT (QPSK +-9, 16-QAM +-4 / +-12); a bit is known when its codeword
                          converged or |posterior L| >= REL_THR; a word is used when all its bits are known (filler words are always known)
           per data bin   S = sum conj(x^) z ,  Eh = sum |x^|^2 / 2        over the data symbols of the packet
                          N1 = W0H * T + 4 S ,  M1 = T * (W0H + Eh)         (prior: the LTS estimate, weight W0H = 216 = 3 bins * A^2 / 2)
                          G  = sat16(N1 * 12288 / M1)                       (= A * c, c = refined / old channel ratio; reciprocal ROM, see ca_ratio)
                          r  = chest_one(G)  = 1 / c  as mantissa / exponent (the channel-estimator arithmetic, second instance)
           second pass    z' = equalize(z, r)  ->  demapper (same per-bin parameters)  ->  deinterleaver  ->  LDPC for the codewords that failed
"""
from __future__ import annotations

import numpy as np

import interleaver_ref as ilr
import ldpc_fixed_ref as lf
import phy2_fixed_ref as F
import phy2_ref as P
import rx_fixed_ref as rf
import scrambler_ref

UA_C_MID = 57
UA_C_OUT = 51
REL_THR = 24
W0H = 216
RECIP = np.array([min(65535, int(round((1 << 27) / m))) for m in range(2048, 4096)], dtype=np.int64)      # 1 / mantissa, mantissa in [2048, 4095]


# ------------------------------------------------------------------ Patch A
def demap_soft_ua(xr, xi, T, gm, ge):
    """16-QAM LLRs [I b0, I b1, Q b0, Q b1] with the uncertainty-aware slopes (see module doc)."""
    out = np.zeros((len(xr), 4), np.int64)
    for k in range(len(xr)):
        sh = F.SH_C - int(ge[k])
        t = int(T[k])
        for ax, x in enumerate((int(xr[k]), int(xi[k]))):
            a = abs(x)
            d = a - t
            l1 = (d * UA_C_MID) >> 6
            if d <= 0:
                l0 = -x
            else:
                mag = t + ((d * UA_C_OUT) >> 6)
                l0 = -mag if x > 0 else mag
            for b, lv in enumerate((l0, l1)):
                p = lv * int(gm[k])
                v = (p << -sh) if sh <= 0 else ((p + (1 << (sh - 1))) >> sh)
                out[k, 2 * ax + b] = max(-F.LLR_MAX, min(F.LLR_MAX, v))
    return out


def demap(xr, xi, T, gm, ge, qpsk, ua):
    if qpsk or not ua:
        return F.demap_soft(xr, xi, T, gm, ge, qpsk=qpsk)
    return demap_soft_ua(xr, xi, T, gm, ge)


# ------------------------------------------------------------------ decoding with access to the posterior values
def decode_cw(llr, nsym, mode, iters=10):
    """llr: list of (1100, 4 | 2) arrays -> (hard (ncw, 2160), iterations, converged, posterior L (ncw, 2160))."""
    m = P.layout(mode)
    deint = P.deinterleave_llr(np.asarray(llr, dtype=float))
    cw = np.rint(deint[:, :m["cw"] * P.CODE_N]).astype(np.int64).reshape(nsym * m["cw"], P.CODE_N)
    return lf.decode(np.clip(cw, -31, 31), iters, base=m["base"], return_post=True)


def payload_bytes(hard, mode, nbytes):
    k = P.layout(mode)["k"]
    raw = scrambler_ref.scramble([int(b) for b in np.packbits(hard[:, :k].reshape(-1))])
    return bytes(raw[:nbytes])


# ------------------------------------------------------------------ Patch B
_LEV4 = {0b00: -12, 0b01: -4, 0b11: 4, 0b10: 12}          # 16-QAM Gray pair -> level in quarter units


def remod_words(hard_sym, known_sym, mode):
    """hard_sym / known_sym: coded bits (and their known flags) of one OFDM symbol incl. the filler bits, coded-bit order.
    Returns per transmitted data bin m: (xr, xi) in quarter units and the used flag."""
    lay = P.layout(mode)
    bps = lay["bits"]
    w = hard_sym.reshape(-1, bps)
    kw = known_sym.reshape(-1, bps).all(axis=1)
    if lay["mod"] == "qpsk":
        words = ilr.interleave([int(a) << 1 | int(b) for a, b in w], 4, 0)
    else:
        words = ilr.interleave([int(a) << 3 | int(b) << 2 | int(c) << 1 | int(d) for a, b, c, d in w], 4, 1)
    used = np.array(ilr.interleave([int(v) for v in kw], 4, 0), dtype=bool)
    xr = np.zeros(len(words), np.int64)
    xi = np.zeros(len(words), np.int64)
    for m_, wd in enumerate(words):
        if lay["mod"] == "qpsk":
            xr[m_] = 9 if (wd >> 1) & 1 else -9
            xi[m_] = 9 if wd & 1 else -9
        else:
            xr[m_] = _LEV4[(wd >> 2) & 3]
            xi[m_] = _LEV4[wd & 3]
    return xr, xi, used


def ca_ratio(n1r, n1i, m1):
    """G = sat16(N1 * 12288 / M1) with the reciprocal ROM: M1 = mant * 2^e, mant in [2048, 4095];  G = (3 * N1 * RECIP[mant] + rnd) >> (15 + e)."""
    m1 = int(m1)
    if m1 <= 0:
        return 12288, 0
    e = m1.bit_length() - 12
    mant = (m1 >> e) if e >= 0 else (m1 << -e)
    r = int(RECIP[mant - 2048])
    sh = 15 + e
    out = []
    for v in (int(n1r), int(n1i)):
        p = 3 * v * r
        g = (p + (1 << (sh - 1))) >> sh if sh > 0 else p << -sh
        out.append(max(-32767, min(32767, g)))
    return out[0], out[1]


def ca_weights(z_list, T, hard, done, L, mode):
    """z_list: [(zr, zi)] tracker outputs of the 1100 data bins per data symbol; T: per-bin threshold (16 bit).
    Returns (mr, mi, E) correction weights per data bin and diagnostics."""
    lay = P.layout(mode)
    nsym = len(z_list)
    nb = len(T)
    sr = np.zeros(nb, np.int64); si = np.zeros(nb, np.int64); eh = np.zeros(nb, np.int64)
    cwb = hard.reshape(nsym, lay["cw"] * P.CODE_N)
    known = (np.abs(L) >= REL_THR) | done[:, None]
    kn = known.reshape(nsym, lay["cw"] * P.CODE_N)
    fill = lay["fill"]
    nused = 0
    for s in range(nsym):
        xr, xi, used = remod_words(np.concatenate([cwb[s], fill]), np.concatenate([kn[s], np.ones(len(fill), bool)]), mode)
        zr, zi = np.asarray(z_list[s][0], np.int64), np.asarray(z_list[s][1], np.int64)
        u = used.astype(np.int64)
        sr += u * (xr * zr + xi * zi)
        si += u * (xr * zi - xi * zr)
        eh += u * ((xr * xr + xi * xi) >> 1)
        nused += int(used.sum())
    mr = np.zeros(nb, np.int64); mi = np.zeros(nb, np.int64); E = np.zeros(nb, np.int64)
    g_all = []
    for k in range(nb):
        t = int(T[k])
        gr, gi = ca_ratio(W0H * t + 4 * int(sr[k]), 4 * int(si[k]), t * (W0H + int(eh[k])))
        g_all.append((gr, gi))
        mr[k], mi[k], E[k] = rf.chest_one(gr, gi, 1)
    return mr, mi, E, {"used_words": nused, "g": g_all, "sr": sr, "si": si, "eh": eh}


def second_pass(z_list, T, gm, ge, hard, its, done, L, mode, iters=10, ua=False):
    """One code-aided pass. Returns (hard, iterations, converged, diagnostics); codewords that converged in the first pass are kept."""
    lay = P.layout(mode)
    qp = lay["mod"] == "qpsk"
    mr, mi, E, dg = ca_weights(z_list, T, hard, done, L, mode)
    llr2, z2 = [], []
    for zr, zi in z_list:
        xr, xi = rf.equalize(np.asarray(zr, np.int64), np.asarray(zi, np.int64), mr, mi, E)
        z2.append((xr, xi))
        llr2.append(demap(xr, xi, T, gm, ge, qp, ua))
    h2, it2, d2, L2 = decode_cw(llr2, len(z_list), mode, iters)
    keep = done.copy()
    hard_f = np.where(keep[:, None], hard, h2)
    its_f = np.where(keep, its, its + it2)
    done_f = keep | d2
    dg.update({"z2": z2, "llr2": llr2, "weights": (mr, mi, E), "pass2_cw": int((~keep).sum()), "fixed_cw": int((d2 & ~keep).sum())})
    return hard_f, its_f, done_f, dg


def receive_decode(llr, diag, nsym, mode, nbytes, iters=10, ua=False, ca=False):
    """Baseline / Patch A / Patch B decode of one packet. llr, diag: output of phy2_fixed_ref.receive_symbols (llr with the baseline demapper;
    for ua the LLRs are recomputed from diag['eq']). Returns (bytes, iterations, converged, info)."""
    lay = P.layout(mode)
    qp = lay["mod"] == "qpsk"
    T, gm, ge = diag["T"], diag["gm"], diag["ge"]
    if ua and not qp:
        llr = [demap_soft_ua(xr, xi, T, gm, ge) for xr, xi in diag["eq"]]
    hard, its, done, L = decode_cw(llr, nsym, mode, iters)
    info = {"pass2": False, "pass1_fail": int((~done).sum())}
    if ca and not done.all():
        hard, its, done, dg = second_pass(diag["eq"], T, gm, ge, hard, its, done, L, mode, iters, ua)
        info.update({"pass2": True, "fixed_cw": dg["fixed_cw"], "used_words": dg["used_words"]})
    return payload_bytes(hard, mode, nbytes), its, done, info
