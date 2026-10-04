"""Bit-exact comparison of two integer / byte sequences (TZ section 22)."""
from __future__ import annotations

import numpy as np


def compare(a, b, name: str = "") -> dict:
    x = np.asarray(a)
    y = np.asarray(b)
    n = min(x.size, y.size)
    diff = np.nonzero(x.ravel()[:n] != y.ravel()[:n])[0]
    return {"name": name, "match": bool(x.size == y.size and diff.size == 0), "len_a": int(x.size), "len_b": int(y.size),
            "n_mismatch": int(diff.size + abs(x.size - y.size)), "first_mismatch": int(diff[0]) if diff.size else None}
