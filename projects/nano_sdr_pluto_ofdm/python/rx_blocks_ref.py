"""Fixed-point golden models of small RX blocks: phy_dc_remove, phy_input_scale, phy_nco (+mixer)."""
import numpy as np

# ------------------------------------------------------------------ DC removal (leaky integrator)
def dc_remove(x, K=10, W=16):
    """est = acc >> K ; acc += x - est ; out = sat(x - est).  acc is a signed (W+K+1)-bit register (no overflow)."""
    acc, out = 0, []
    lo, hi = -(1 << (W - 1)), (1 << (W - 1)) - 1
    for v in x:
        est = acc >> K
        out.append(max(lo, min(hi, int(v) - est)))
        acc += int(v) - est
    return out

# ------------------------------------------------------------------ input scaling (power-of-two gain)
def input_scale(x, sh, W=16):
    """sh > 0: x << sh with saturation; sh < 0: arithmetic right shift with round-half-up; sh == 0 passthrough."""
    lo, hi = -(1 << (W - 1)), (1 << (W - 1)) - 1
    out = []
    for v in x:
        v = int(v)
        if sh >= 0:
            r = v << sh
        else:
            r = (v + (1 << (-sh - 1))) >> (-sh)
        out.append(max(lo, min(hi, r)))
    return out

# ------------------------------------------------------------------ NCO + mixer
NCO_AW = 10          # quarter-wave table address bits (phase[29:20])
NCO_PH_BITS = 12     # phase bits used (phase[31:20])


def nco_table():
    a = np.arange(1 << NCO_AW)
    ang = 2 * np.pi * (a + 0.5) / (1 << NCO_PH_BITS)
    return np.clip(np.floor(np.cos(ang) * 32767.0 + 0.5), -32767, 32767).astype(np.int64)


def nco_cs(phase):
    """(cos, sin) Q1.15 for a 32-bit phase word."""
    T = nco_table()
    idx = (phase >> (32 - NCO_PH_BITS)) & ((1 << NCO_PH_BITS) - 1)
    quad, a = idx >> NCO_AW, idx & ((1 << NCO_AW) - 1)
    n = (1 << NCO_AW) - 1
    t, tr = T[a], T[n - a]
    c = np.select([quad == 0, quad == 1, quad == 2, quad == 3], [t, -tr, -t, tr])
    s = np.select([quad == 0, quad == 1, quad == 2, quad == 3], [tr, t, -tr, -t])
    return c, s


def nco_mix(xi, xq, inc, ph0=0, W=16):
    """y = x * (cos + j sin)(phase_n), phase_n = ph0 + n*inc (mod 2^32); complex mult rounds half-up >>15, saturates to W."""
    xi = np.asarray(xi, dtype=np.int64); xq = np.asarray(xq, dtype=np.int64)
    ph = (ph0 + np.arange(len(xi), dtype=np.int64) * int(inc)) & 0xFFFFFFFF
    c, s = nco_cs(ph)
    lo, hi = -(1 << (W - 1)), (1 << (W - 1)) - 1
    re = np.clip((xi * c - xq * s + 16384) >> 15, lo, hi)
    im = np.clip((xi * s + xq * c + 16384) >> 15, lo, hi)
    return re, im
