"""Symbol-level block interleaver (golden for phy_interleaver).
Geometry: NSYM = ROWS*COLS words per OFDM symbol (1100 = 55 x 20).
  interleave   : out[m] = rot( in[pi(m)], m odd ),   pi(m) = (m % COLS)*ROWS + m // COLS
  deinterleave : out[i] = unrot( in[m(i)], m(i) odd ), m(i) = (i % ROWS)*COLS + i // ROWS  (inverse permutation)
Rot = circular left rotation of the word by ROT_UNIT bits (1 for hard bits in a 4-bit word, 8 for 8-bit LLRs):
alternate symbols swap reliable (MSB) and less reliable (LSB) bit positions.
"""
from phy_params import IL_COLS, IL_ROWS


def _rot(w, width, unit, left=True):
    mask = (1 << width) - 1
    unit %= width
    if left:
        return ((w << unit) | (w >> (width - unit))) & mask
    return ((w >> unit) | (w << (width - unit))) & mask


def pi(m, rows=IL_ROWS, cols=IL_COLS):
    return (m % cols) * rows + m // cols


def pi_inv(i, rows=IL_ROWS, cols=IL_COLS):
    return (i % rows) * cols + i // rows


def interleave(words, width, unit, rows=IL_ROWS, cols=IL_COLS):
    n = rows * cols
    out = []
    for blk in range(0, len(words), n):
        b = words[blk:blk + n]
        for m in range(n):
            w = b[pi(m, rows, cols)]
            out.append(_rot(w, width, unit, True) if (m & 1) else w)
    return out


def deinterleave(words, width, unit, rows=IL_ROWS, cols=IL_COLS):
    n = rows * cols
    out = []
    for blk in range(0, len(words), n):
        b = words[blk:blk + n]
        for i in range(n):
            m = pi_inv(i, rows, cols)
            w = b[m]
            out.append(_rot(w, width, unit, False) if (m & 1) else w)
    return out
