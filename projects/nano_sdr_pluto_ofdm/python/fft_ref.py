"""Bit-exact fixed-point model of phy_fft_core (radix-2 DIF single-path delay feedback).

Per stage (block size 2D, D = N/2 ... 1), for a in x[n], b in x[n+D]:
    s = a + b ; d = a - b                       (W+1 bit)
    s, d = scale(s), scale(d)                   (SHIFT bit set: round-half-up >>1, else saturate to W)
    d   *= W_{2D}^n = exp(-j*2*pi*n/(2D))       (D >= 4: Q1.15 twiddle, round-half-up >>15, saturate to W)
                                                (D == 2: n=1 -> exact multiply by -j (swap/negate, saturate); D == 1: none)
Output stream is in bit-reversed order (raw=True) -- same order as the RTL stream.
Inverse transform = swap(I,Q) around the forward core (done by the wrapper, see ifft_fixed).
"""
import numpy as np

W_DEFAULT = 18
TWW = 16


def sat(v, w):
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return np.clip(v, lo, hi)


def scale(v, sh, w):
    return (v + 1) >> 1 if sh else sat(v, w)


def twiddle(D):
    """Q1.15 twiddles for block 2D: (wr, wi) with W = wr + j*wi = exp(-j*2*pi*n/(2D))."""
    n = np.arange(D)
    th = 2 * np.pi * n / (2 * D)
    wr = np.clip(np.floor(np.cos(th) * 32768.0 + 0.5), -32768, 32767).astype(np.int64)
    wi = np.clip(np.floor(-np.sin(th) * 32768.0 + 0.5), -32768, 32767).astype(np.int64)
    return wr, wi


def cmul(dr, di, wr, wi, w):
    re = (dr * wr - di * wi + 16384) >> 15
    im = (dr * wi + di * wr + 16384) >> 15
    return sat(re, w), sat(im, w)


def fft_fixed(xr, xi, n_log, w=W_DEFAULT, shift_mask=0):
    """Returns (re, im) in RTL stream order (bit-reversed)."""
    N = 1 << n_log
    xr = np.asarray(xr, dtype=np.int64).copy()
    xi = np.asarray(xi, dtype=np.int64).copy()
    assert xr.shape == (N,) and xi.shape == (N,)
    for st in range(n_log):
        D = N >> (st + 1)
        sh = (shift_mask >> st) & 1
        ar, br = xr.reshape(-1, 2, D)[:, 0, :], xr.reshape(-1, 2, D)[:, 1, :]
        ai, bi = xi.reshape(-1, 2, D)[:, 0, :], xi.reshape(-1, 2, D)[:, 1, :]
        sr, si = scale(ar + br, sh, w), scale(ai + bi, sh, w)
        dr, di = scale(ar - br, sh, w), scale(ai - bi, sh, w)
        if D >= 4:
            wr, wi = twiddle(D)
            dr, di = cmul(dr, di, wr[None, :], wi[None, :], w)
        elif D == 2:
            n1r, n1i = dr[:, 1].copy(), di[:, 1].copy()     # multiply element n=1 by -j: (r,i)->(i,-r)
            dr = dr.copy(); di = di.copy()
            dr[:, 1], di[:, 1] = sat(n1i, w), sat(-n1r, w)
        xr = np.stack([sr, dr], axis=1).reshape(-1)
        xi = np.stack([si, di], axis=1).reshape(-1)
        # stream order: for each block, first the sums (phase 1 outputs) and then diffs of the same block
    return xr, xi


def bitrev_perm(n_log):
    N = 1 << n_log
    return np.array([int(format(i, f"0{n_log}b")[::-1], 2) for i in range(N)])


def natural(xr, xi, n_log):
    """Reorder RTL-stream (bit-reversed) output to natural bin order."""
    p = bitrev_perm(n_log)
    outr = np.zeros_like(xr); outi = np.zeros_like(xi)
    outr[p] = xr
    outi[p] = xi
    return outr, outi


def ifft_fixed(xr, xi, n_log, w=W_DEFAULT, shift_mask=0):
    """Inverse via I/Q swap around the forward core (output in stream order, I/Q swapped back)."""
    yr, yi = fft_fixed(xi, xr, n_log, w, shift_mask)
    return yi, yr
