"""Numerical-tolerance comparison for quantities that are not expected to be bit-exact (TZ section 22)."""
from __future__ import annotations

import numpy as np


def compare(a, b, atol: float = 0.0, rtol: float = 0.0, name: str = "") -> dict:
    x = np.asarray(a, dtype=np.complex128).ravel()
    y = np.asarray(b, dtype=np.complex128).ravel()
    n = min(x.size, y.size)
    if n == 0:
        return {"name": name, "ok": False, "reason": "empty"}
    e = np.abs(x[:n] - y[:n])
    thr = atol + rtol * np.abs(y[:n])
    ref_pow = float(np.mean(np.abs(y[:n]) ** 2)) or 1.0
    return {"name": name, "ok": bool(np.all(e <= thr)), "max_abs_err": float(e.max()), "rms_err": float(np.sqrt(np.mean(e ** 2))),
            "nrmse_db": float(10 * np.log10(max(np.mean(e ** 2) / ref_pow, 1e-30))), "n": int(n), "len_a": int(x.size), "len_b": int(y.size)}
