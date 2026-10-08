"""PHY header symbol (golden for phy_hdr_gen / phy_hdr_dec).

One OFDM symbol of 1100 QPSK bins after the LTS carries a 16 bit header word {mode(1), nsyms(8), rsv(3), crc4(4)} (MODE_ID 0 = MAX RANGE,
1 = MAX RATE).  The 16 bits are repeated over the 2200 coded bits (bit i = hdr[15 - i % 16]) and XORed with a PN sequence (15 bit
LFSR x^15 + x^14 + 1 style: out = lf[14] ^ lf[13], lf <- {lf[13:0], out}, seed HDR_SEED, one step per bit); bit 1 = +HDR_AMP, bit 0 = -HDR_AMP
on I (even bits) and Q (odd bits).  RX: LLR (positive = bit 0) x PN sign, summed per (i % 16); negative sum = bit 1; CRC-4 check."""
from __future__ import annotations

import numpy as np

from phy_params import HDR_AMP, HDR_SEED, NUM_DATA_SC


def crc4(bits12: int) -> int:
    c = 0
    for i in range(11, -1, -1):
        fb = ((c >> 3) & 1) ^ ((bits12 >> i) & 1)
        c = ((c << 1) & 0xF) ^ (0b0011 if fb else 0)
    return c


def word(mode: int, nsyms: int) -> int:
    body = ((mode & 1) << 11) | ((nsyms & 0xFF) << 3)
    return (body << 4) | crc4(body)


def pn(n: int) -> np.ndarray:
    lf, out = HDR_SEED, []
    for _ in range(n):
        s = ((lf >> 14) ^ (lf >> 13)) & 1
        out.append(s)
        lf = ((lf << 1) & 0x7FFF) | s
    return np.array(out, dtype=np.int64)


_PN = pn(2 * NUM_DATA_SC)


def tx_bins(mode: int, nsyms: int) -> np.ndarray:
    """(1100, 2) integer I/Q levels of the header symbol."""
    w = word(mode, nsyms)
    bits = np.array([(w >> (15 - (i % 16))) & 1 for i in range(2 * NUM_DATA_SC)], dtype=np.int64) ^ _PN
    lv = np.where(bits == 1, HDR_AMP, -HDR_AMP)
    return lv.reshape(NUM_DATA_SC, 2)


def decode(llr: np.ndarray) -> dict:
    """llr: (1100, 2) integer LLRs (positive = bit 0, 6 bit) -> {ok, mode, nsyms, conf}."""
    llr = np.asarray(llr, dtype=np.int64).reshape(-1)
    v = np.where(_PN == 1, -llr, llr)
    acc = np.zeros(16, dtype=np.int64)
    for i in range(len(v)):
        acc[i % 16] += v[i]
    h = 0
    for j in range(16):
        h = (h << 1) | (1 if acc[j] < 0 else 0)
    ok = crc4(h >> 4) == (h & 0xF)
    return {"ok": bool(ok), "mode": (h >> 15) & 1, "nsyms": (h >> 7) & 0xFF, "conf": int(np.min(np.abs(acc))), "word": h}
