"""Bit-exact fixed-point model of the RTL LDPC decoder (layered normalised min-sum), golden for phy_ldpc_dec.

Number formats (parameters of the RTL, see phy_ldpc_pkg): channel LLR 6 bit signed (-31..31 after symmetric clipping),
posterior L and variable-to-check message Q 8 bit signed saturated to -127..127, check magnitudes min1/min2 7 bit.
Normalisation alpha = 0.75 : R = m - (m >> 2).
Per layer (block row i, entries e = (column c_e, shift s_e)):
    Q_e[r]  = sat( L[c_e][(r + s_e) % Z] - R_old_e[r] )
    min1/min2/idx of |Q_e[r]| over e, sign parity of Q_e[r]
    R_new_e[r] = sign * ( (e == idx ? min2 : min1) - ((e == idx ? min2 : min1) >> 2) ),  sign = parity ^ sgn(Q_e[r])
    L[c_e][(r + s_e) % Z] = sat( Q_e[r] + R_new_e[r] )
Early termination: stop after SYNDROME_LAYERS consecutive layers whose parity (from the signs of the L values read) is zero and
whose write-back changed no sign; at most `max_iter` iterations.  Output = sign bits of L (1 = negative); the third return value is `done` (6 clean layers reached, i.e. converged).
The RTL keeps every column in the rotation of the last layer that used it; that is invisible at this level (pure re-indexing).
"""
from __future__ import annotations

import numpy as np

import ldpc_ref as lr

LCH_MAX = 31
L_MAX = 127
M_MAX = 127         # check-node magnitudes (min1/min2) 7 bit
Z, MB, NB = lr.Z, lr.MB, lr.NB


def quant_llr(llr: np.ndarray, scale: float = 1.0) -> np.ndarray:
    return np.clip(np.rint(np.asarray(llr) * scale), -LCH_MAX, LCH_MAX).astype(np.int64)


def layer_entries(base=None):
    base = lr.H_BASE if base is None else base
    return [[(j, int(base[i, j])) for j in range(NB) if base[i, j] >= 0] for i in range(MB)]


def decode(llr_q: np.ndarray, max_iter: int = 8, base=None, early_stop: bool = True):
    """llr_q: (B, N) int channel LLRs (positive = bit 0). Returns (hard (B, N) uint8, iterations (B,), parity_ok (B,))."""
    ent = layer_entries(base)
    llr_q = np.atleast_2d(llr_q).astype(np.int64)
    B = llr_q.shape[0]
    L = llr_q.reshape(B, NB, Z).copy()
    # state per layer: min1, min2 (magnitudes, 7 bit), idx, signs (deg bits), parity -> kept as full R_old messages equivalently
    st = [None] * MB
    its = np.full(B, max_iter)
    good = np.zeros(B, int)             # consecutive clean layers
    done = np.zeros(B, bool)
    frozen = np.zeros((B, lr.N), np.uint8)
    for it in range(1, max_iter + 1):
        for i in range(MB):
            e = ent[i]
            deg = len(e)
            # R_old for each entry
            if st[i] is None:
                Rold = np.zeros((B, deg, Z), np.int64)
            else:
                m1, m2, idx, sg, par = st[i]            # (B,Z) each, sg: (B,deg,Z) sign bit of Q
                Rold = np.zeros((B, deg, Z), np.int64)
                for k in range(deg):
                    mag = np.where(idx == k, m2, m1)
                    mag = mag - (mag >> 2)
                    neg = (par ^ sg[:, k]).astype(bool)
                    Rold[:, k] = np.where(neg, -mag, mag)
            Lrd = np.stack([np.roll(L[:, j], -s, axis=1) for j, s in e], axis=1)    # (B,deg,Z)
            # parity of the hard decisions read (for early termination)
            par_read = (np.bitwise_xor.reduce((Lrd < 0).astype(np.uint8), axis=1)).any(axis=1)      # (B,) any check unsatisfied
            Q = np.clip(Lrd - Rold, -L_MAX, L_MAX)
            mag = np.minimum(np.abs(Q), M_MAX)
            idx = np.argmin(mag, axis=1)                                         # first minimum
            m1 = np.take_along_axis(mag, idx[:, None, :], axis=1)[:, 0]
            mag2 = mag.copy()
            np.put_along_axis(mag2, idx[:, None, :], 1 << 20, axis=1)
            m2 = mag2.min(axis=1)
            sg = (Q < 0).astype(np.uint8)
            par = np.bitwise_xor.reduce(sg, axis=1)
            st[i] = (m1, m2, idx, sg, par)
            Lnew = np.zeros_like(Q)
            for k in range(deg):
                magk = np.where(idx == k, m2, m1)
                magk = magk - (magk >> 2)
                neg = (par ^ sg[:, k]).astype(bool)
                Rn = np.where(neg, -magk, magk)
                Lnew[:, k] = np.clip(Q[:, k] + Rn, -L_MAX, L_MAX)
            flipped = ((Lnew < 0) != (Lrd < 0)).any(axis=(1, 2))
            for k, (j, s) in enumerate(e):
                L[:, j] = np.roll(Lnew[:, k], s, axis=1)
            clean = ~par_read & ~flipped
            good = np.where(clean, good + 1, 0)
            if early_stop:
                newly = (good >= MB) & ~done
                its[newly] = it
                if newly.any():
                    frozen[newly] = (L[newly].reshape(-1, lr.N) < 0).astype(np.uint8)
                done |= newly
        if early_stop and done.all():
            break
    hard = (L.reshape(B, lr.N) < 0).astype(np.uint8)
    hard = np.where(done[:, None], frozen, hard)           # a codeword that converged is frozen at the moment it converged
    return hard, its, done
