"""OFDM frequency-domain construction (golden for phy_ofdm_mapper / phy_pilot_insert / phy_preamble_gen).
Streams are in natural bin order b = 0..FFT_SIZE-1. Active bins: 1..600 (stream index s=b-1) and 1448..2047 (s=600+b-1448).
Pilot slots: s % 12 == 6 ; pilot value = +-PILOT_AMP (real), sign from x^15+x^14+1 LFSR (seed PILOT_SEED, restart each symbol).
Preamble type 0 (sync): even active bins only, +-SYNC_AMP, LFSR SYNC_SEED advancing per even active bin.
Preamble type 1 (LTS): all active bins, +-PILOT_AMP, LFSR LTS_SEED advancing per active bin.
Data symbols fill the non-pilot active slots in stream order."""
import numpy as np
from phy_params import *


def s_of_bin(b):
    if 1 <= b <= NUM_POS_SC:
        return b - 1
    if NEG_FIRST_BIN <= b < FFT_SIZE:
        return NUM_POS_SC + b - NEG_FIRST_BIN
    return -1


def is_pilot_slot(s):
    return s >= 0 and s % PILOT_SPACING == PILOT_OFFSET


def lfsr_bits(seed, n):
    s, out = seed, []
    for _ in range(n):
        fb = ((s >> 14) ^ (s >> 13)) & 1
        s = ((s << 1) | fb) & 0x7FFF
        out.append(fb)
    return out


def map_bins(qam):
    """qam: list of (i,q) for NUM_DATA_SC data symbols -> list of (pilot_flag, re, im) for FFT_SIZE bins."""
    out, k = [], 0
    for b in range(FFT_SIZE):
        s = s_of_bin(b)
        if s < 0:
            out.append((0, 0, 0))
        elif is_pilot_slot(s):
            out.append((1, 0, 0))
        else:
            out.append((0, int(qam[k][0]), int(qam[k][1])))
            k += 1
    assert k == len(qam) == NUM_DATA_SC
    return out


def insert_pilots(bins):
    bits = lfsr_bits(PILOT_SEED, NUM_PILOTS)
    p, out = 0, []
    for flag, re, im in bins:
        if flag:
            out.append((-PILOT_AMP if bits[p] else PILOT_AMP, 0))
            p += 1
        else:
            out.append((re, im))
    assert p == NUM_PILOTS
    return out


def preamble(kind):
    out = []
    if kind == 0:
        n_even = sum(1 for b in range(FFT_SIZE) if s_of_bin(b) >= 0 and b % 2 == 0)
        bits, k = lfsr_bits(SYNC_SEED, n_even), 0
        for b in range(FFT_SIZE):
            if s_of_bin(b) >= 0 and b % 2 == 0:
                out.append((-SYNC_AMP if bits[k] else SYNC_AMP, 0)); k += 1
            else:
                out.append((0, 0))
    else:
        bits, k = lfsr_bits(LTS_SEED, NUM_ACTIVE_SC), 0
        for b in range(FFT_SIZE):
            if s_of_bin(b) >= 0:
                out.append((-PILOT_AMP if bits[k] else PILOT_AMP, 0)); k += 1
            else:
                out.append((0, 0))
    return out
