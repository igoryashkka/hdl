"""Golden (reference) data used as ground truth and for RTL-vs-Python comparison: thin wrappers over the existing models."""
from __future__ import annotations

import numpy as np

from .. import refs


def tx_iq(payload: bytes, gain: int = 16384) -> np.ndarray:
    return np.array([complex(a, b) for a, b in refs.tx_ref.tx_frame(list(payload), gain=gain)])


def tx_data_symbols(payload: bytes, code: str = "none", layout=1):
    """(nsym, 1100) complex ideal 16-QAM points (TX constellation units, 4096 per level) + interleaved nibble words.
    code "ldpc": the data symbols of the coded PHY (450 payload bytes per symbol)."""
    if code != "ldpc":
        return refs.tx_ref.tx_data_symbols(list(payload))
    lay = refs.phy2_ref.layout(layout)
    nsym = -(-len(payload) // lay["bytes"])
    words = refs.phy2_ref.tx_words(bytes(payload), nsym, "ldpc", layout)
    if lay["mod"] == "qpsk":
        bits = np.array([[(w >> 1) & 1, w & 1] for w in words]).reshape(-1)
        iq = refs.qam_ref.map_symbols(bits, order=4, unit=refs.P.QPSK_UNIT)
    else:
        bits = np.array([[(w >> (3 - k)) & 1 for k in range(4)] for w in words]).reshape(-1)
        iq = refs.qam_ref.map_symbols(bits, order=16)
    return (iq[:, 0] + 1j * iq[:, 1]).reshape(nsym, refs.P.NUM_DATA_SC), words


def tx_bits(payload: bytes) -> np.ndarray:
    return np.unpackbits(np.frombuffer(bytes(payload), dtype=np.uint8))


def pad_to_symbols(payload: bytes) -> bytes:
    n = -(-len(payload) // refs.BYTES_PER_SYM) * refs.BYTES_PER_SYM
    return bytes(payload) + bytes(n - len(payload))


def frame_layout(nsyms: int, pre: int = 2) -> dict:
    """Sample offsets inside one TX frame: sync, LTS, [header], data symbols (CP included, body starts +CP_LEN); pre = 2 (legacy) | 3."""
    s, cp = refs.SYM_LEN, refs.P.CP_LEN
    return {"sync_start": 0, "lts_start": s, "lts_body": s + cp,
            "data_starts": [(pre + k) * s for k in range(nsyms)], "length": (nsyms + pre) * s}
