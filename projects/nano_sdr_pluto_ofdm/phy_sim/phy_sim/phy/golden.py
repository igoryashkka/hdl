"""Golden (reference) data used as ground truth and for RTL-vs-Python comparison: thin wrappers over the existing models."""
from __future__ import annotations

import numpy as np

from .. import refs


def tx_iq(payload: bytes, gain: int = 16384) -> np.ndarray:
    return np.array([complex(a, b) for a, b in refs.tx_ref.tx_frame(list(payload), gain=gain)])


def tx_data_symbols(payload: bytes):
    """(nsym, 1100) complex ideal 16-QAM points (TX constellation units, 4096 per level) + interleaved nibble words."""
    return refs.tx_ref.tx_data_symbols(list(payload))


def tx_bits(payload: bytes) -> np.ndarray:
    return np.unpackbits(np.frombuffer(bytes(payload), dtype=np.uint8))


def pad_to_symbols(payload: bytes) -> bytes:
    n = -(-len(payload) // refs.BYTES_PER_SYM) * refs.BYTES_PER_SYM
    return bytes(payload) + bytes(n - len(payload))


def frame_layout(nsyms: int) -> dict:
    """Sample offsets inside one TX frame: sync, LTS, data symbols (CP included, body starts +CP_LEN)."""
    s, cp = refs.SYM_LEN, refs.P.CP_LEN
    return {"sync_start": 0, "lts_start": s, "lts_body": s + cp,
            "data_starts": [(2 + k) * s for k in range(nsyms)], "length": (nsyms + 2) * s}
