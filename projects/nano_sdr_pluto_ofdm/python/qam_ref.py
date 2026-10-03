"""Bit-exact fixed-point QAM mapper / max-log soft demapper (golden model for phy_qam_mapper/demapper).
Bit order per symbol: [I g0..g(m-1), Q g0..g(m-1)], g0 = MSB. Gray per axis. LLR>0 => bit 0."""
import numpy as np
from phy_params import *

def _m(order): return (order.bit_length() - 1) // 2

def gray2bin(g):
    b = g
    while g:
        g >>= 1
        b ^= g
    return b

def map_symbols(bits, order=QAM_ORDER, unit=QAM_UNIT):
    m = _m(order); M = 1 << m; bps = 2 * m
    bits = np.asarray(bits, dtype=np.int64).reshape(-1, bps)
    out = []
    for row in bits:
        gi = int("".join(map(str, row[:m])), 2); gq = int("".join(map(str, row[m:])), 2)
        out.append((unit * (2 * gray2bin(gi) - (M - 1)), unit * (2 * gray2bin(gq) - (M - 1))))
    return np.array(out, dtype=np.int64)

def _sat(v, w):
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return max(lo, min(hi, v))

def _axis_llr(x, m, unit, gain, shift, w):
    llrs = [_sat((-x * gain) >> shift, w)]
    t = x
    for k in range(1, m):
        t = abs(t) - unit * (1 << (m - k))
        llrs.append(_sat((t * gain) >> shift, w))
    return llrs

def demap_llr(iq, order=QAM_ORDER, unit=QAM_UNIT, gain=LLR_GAIN, shift=LLR_SHIFT, w=LLR_W):
    m = _m(order)
    out = []
    for i, q in np.asarray(iq, dtype=np.int64).reshape(-1, 2):
        out.append(_axis_llr(int(i), m, unit, gain, shift, w) + _axis_llr(int(q), m, unit, gain, shift, w))
    return np.array(out, dtype=np.int64)
