"""Float prototype for ТЗ 004 (before any RTL): how much can the patches gain at all, and where is the remaining loss?

Frequency-domain link model (same as phy3_test): LTS + data symbols through H, AWGN. Receiver variants (codeword error rate is reported):
  base       LS estimate from the LTS with 3-bin smoothing, per-bin LLR weights from the noise only            = today's RTL algorithm in float
  ua         Patch A: uncertainty-aware LLR, noise variance of a constellation hypothesis a = sigma^2 (1 + kappa |a|^2), kappa = 1 / (A^2 N_eff)
             (the channel-estimate error multiplies the transmitted symbol): region-dependent LLR slopes for 16-QAM, a constant for QPSK
  ua_genie   bound of any uncertainty-aware demapper: the true per-bin estimation error power is known to the demapper
  iter       Patch B: one code-aided pass, converged codewords re-modulated, H re-estimated from LTS + those symbols, all symbols demodulated again
  iter_rel   Patch B with reliable bits of ALL codewords (|posterior L| >= REL_THR), also from codewords that did not converge
  iter_ua    iter_rel + Patch A with kappa of the refined estimate
  wiener     diagnostic for the next algorithm: LS estimate filtered by a delay-domain window (keeps delays -16 .. 160 samples) instead of 3-bin smoothing
  genie      perfect channel knowledge (upper bound of everything that improves the channel estimate)
usage: python rxenh_proto.py [mode] [kind] [nsym] [npk] [snr_lo] [snr_hi] [step]"""
import sys

import numpy as np

sys.path.insert(0, ".")
import interleaver_ref as ilr
import ldpc_fixed_ref as lf
import phy2_ref as P
import phy2_test as T
import phy3_test as T3
import scrambler_ref
from phy_params import FFT_SIZE, PILOT_AMP, QAM_UNIT, QPSK_UNIT

DS, PS = P._DS, P._PS
A = float(PILOT_AMP)
NS = 3                                   # smoothing window (bins)
REL_THR = 24                             # |posterior L| (8 bit, +-127) from which a decoded bit counts as reliable
U = float(QAM_UNIT)


def smooth(h):
    out = np.empty_like(h)
    n = len(h)
    for k in range(n):
        lo, hi = max(0, k - 1), min(n - 1, k + 1)
        out[k] = h[lo:hi + 1].mean()
    return out


def wiener(g, d0=-16, d1=160):
    """Delay-domain window: active bins -> 2048 grid -> IFFT -> keep delays d0..d1 -> FFT.  Band edges are handled by iterating the
    projection (known bins kept, unknown bins from the model) a few times."""
    full = np.zeros(FFT_SIZE, complex)
    mask = np.zeros(FFT_SIZE, bool)
    mask[P.ACT] = True
    win = np.zeros(FFT_SIZE)
    idx = np.arange(d0, d1 + 1) % FFT_SIZE
    win[idx] = 1.0
    est = np.zeros(FFT_SIZE, complex)
    for _ in range(12):
        full[:] = est
        full[P.ACT] = g
        est = np.fft.fft(np.fft.ifft(full) * win)
    return est[P.ACT]


def llr16_axis(x, var, kap, e_other):
    """max-log LLRs of one axis of 16-QAM with a hypothesis-dependent variance var * (1 + kap (a^2 + e_other))."""
    lev = np.array([-3.0, -1.0, 1.0, 3.0]) * U
    b0 = np.array([0, 0, 1, 1]); b1 = np.array([0, 1, 1, 0])
    v = var[..., None] * (1.0 + (kap[..., None] if np.ndim(kap) else kap) * (lev ** 2 + e_other))
    d = (x[..., None] - lev) ** 2 / (2 * v) + (0.5 * np.log(v) if np.any(kap) else 0.0)
    l0 = d[..., b0 == 1].min(-1) - d[..., b0 == 0].min(-1)
    l1 = d[..., b1 == 1].min(-1) - d[..., b1 == 0].min(-1)
    return l0, l1


def demap(xh, var, mod, kap=0.0):
    if mod == "qpsk":
        a = float(QPSK_UNIT)
        v = var * (1.0 + kap * 2 * a * a)
        return np.stack([-2 * a * xh.real / v, -2 * a * xh.imag / v], axis=-1)
    li0, li1 = llr16_axis(xh.real, var, kap, 5 * U * U)
    lq0, lq1 = llr16_axis(xh.imag, var, kap, 5 * U * U)
    return np.stack([li0, li1, lq0, lq1], axis=-1)


def decode_post(q, iters, base):
    hard, it, done, L = lf.decode(q, iters, base=base, return_post=True)
    return hard, it, done, L


VARIANTS = ("base", "ua", "ua_genie", "iter", "iter_rel", "iter_ua", "wiener", "genie")


def run(mode, snr, kind, nsym=2, npk=40, seed=1, variants=VARIANTS, iters=10):
    rng = np.random.default_rng(seed)
    T.rng = rng
    lay = P.layout(mode)
    mod = lay["mod"]
    H = T.chan(kind)
    sigma2 = np.mean(np.abs(H) ** 2) * P.P_DATA / 10 ** (snr / 10)
    kap0 = 1.0 / (A * A * NS)
    err = {v: 0 for v in variants}
    ncw = 0
    for _ in range(npk):
        nb = lay["bytes"] * nsym
        pay = bytes(rng.integers(0, 256, nb, dtype=np.uint8))
        words = P.tx_words(pay, nsym, "ldpc", mode)
        ylts, ys = T3.make_y3(words, mode, H, sigma2, nsym, rng=rng)
        ya = [y[P.ACT] for y in ys[1:]]                                       # skip the header symbol
        g = ylts[P.ACT] * P._lts_sg() / A
        h_s = smooth(g)
        info = np.unpackbits(np.frombuffer(bytes(scrambler_ref.scramble(list(pay))), np.uint8)).reshape(nsym * lay["cw"], lay["k"])

        def decode(h_est, kap):
            llrs = []
            for y in ya:
                yd, hd = y[DS], h_est[DS]
                var = sigma2 / np.abs(hd) ** 2 / 2.0
                k_ = kap[DS] * np.abs(hd) ** 0 if np.ndim(kap) else kap
                llrs.append(demap(yd / hd, var, mod, k_))
            de = P.deinterleave_llr(np.stack(llrs))
            cw = de[:, :lay["cw"] * P.CODE_N].reshape(nsym * lay["cw"], P.CODE_N)
            q = np.clip(np.rint(cw * (8.0 / max(np.mean(np.abs(cw)), 1e-9))), -31, 31).astype(np.int64)     # per-packet LLR scale (mean |LLR| = 8)
            hard, it, done, L = decode_post(q, iters, lay["base"])
            ok = (hard[:, :lay["k"]] == info).all(axis=1)
            return hard, it, done, ok, L

        def refine(hard, done, L, mode_sel):
            """LS re-estimate from the LTS prior and the re-modulated symbols; mode_sel: 'conv' (converged codewords) | 'rel' (reliable bits)."""
            num = (A * A * NS) * h_s.copy()
            den = np.full(len(h_s), A * A * NS)
            cwbits = hard.reshape(nsym, lay["cw"], P.CODE_N)
            rel = (np.abs(L) >= REL_THR).reshape(nsym, lay["cw"], P.CODE_N) if mode_sel == "rel" else None
            bps = lay["bits"]
            for s in range(nsym):
                bits = np.concatenate([cwbits[s].reshape(-1), lay["fill"]])
                if mode_sel == "rel":
                    known = np.concatenate([rel[s].reshape(-1) | np.repeat(done[s * lay["cw"]:(s + 1) * lay["cw"]], P.CODE_N), np.ones(len(lay["fill"]), bool)])
                else:
                    known = np.concatenate([np.repeat(done[s * lay["cw"]:(s + 1) * lay["cw"]], P.CODE_N), np.ones(len(lay["fill"]), bool)])
                w = bits.reshape(-1, bps)
                kw = known.reshape(-1, bps).all(axis=1)
                if mod == "qpsk":
                    wl = ilr.interleave([int(a) << 1 | int(b) for a, b in w], 4, 0)
                else:
                    wl = ilr.interleave([int(a) << 3 | int(b) << 2 | int(c) << 1 | int(d) for a, b, c, d in w], 4, 1)
                kl = np.array(ilr.interleave([int(v) for v in kw], 4, 0), bool)
                x = T3.sym_points(wl, mode)[0]
                yd = ya[s][DS]
                num[DS[kl]] += np.conj(x[kl]) * yd[kl]
                den[DS[kl]] += np.abs(x[kl]) ** 2
            return num / den, den / (A * A)

        res = {}
        base = decode(h_s, 0.0)
        res["base"] = base
        if "ua" in variants:
            res["ua"] = decode(h_s, kap0)
        if "ua_genie" in variants:
            res["ua_genie"] = decode(h_s, np.abs(h_s - H) ** 2 / sigma2)          # kappa per bin = |error|^2 / sigma^2 (known only to a genie)
        if "wiener" in variants:
            res["wiener"] = decode(wiener(g), 0.0)
        if "genie" in variants:
            res["genie"] = decode(H, 0.0)
        for name, sel, ua in (("iter", "conv", False), ("iter_rel", "rel", False), ("iter_ua", "rel", True)):
            if name not in variants:
                continue
            hard, it, done, ok, L = decode(h_s, kap0) if ua else base
            if done.all():
                res[name] = (hard, it, done, ok, L)
                continue
            h2, neff = refine(hard, done, L, sel)
            r2 = decode(h2, 1.0 / (A * A * np.maximum(neff, 1.0)) if ua else 0.0)
            res[name] = (r2[0], r2[1], r2[2], np.where(done, ok, r2[3]), r2[4])
        ncw += nsym * lay["cw"]
        for v in variants:
            err[v] += int((~res[v][3]).sum())
    return {v: err[v] / ncw for v in variants}, ncw


if __name__ == "__main__":
    mode = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    kind = sys.argv[2] if len(sys.argv) > 2 else "awgn"
    nsym = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    npk = int(sys.argv[4]) if len(sys.argv) > 4 else 40
    lo = float(sys.argv[5]) if len(sys.argv) > 5 else (1.0 if mode == 0 else 11.0)
    hi = float(sys.argv[6]) if len(sys.argv) > 6 else (4.0 if mode == 0 else 15.5)
    st = float(sys.argv[7]) if len(sys.argv) > 7 else 0.5
    for s in np.arange(lo, hi + 1e-9, st):
        r, n = run(mode, float(s), kind, nsym, npk)
        print(mode, kind, nsym, "snr", round(float(s), 2), "ncw", n, {k: round(v, 3) for k, v in r.items()}, flush=True)
