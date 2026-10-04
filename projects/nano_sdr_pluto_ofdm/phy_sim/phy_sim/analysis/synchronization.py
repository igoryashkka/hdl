"""Schmidl-Cox P/R/M analysis, detection vs ground truth, timing and CFO error (TZ section 13)."""
from __future__ import annotations

import numpy as np

from .. import refs


def sc_metric(iq: np.ndarray, L: int = refs.rx_ref.L) -> dict:
    """Float Schmidl-Cox sequences P(n), R(n), M(n) = |P|^2/R^2 (n = start index of the 2L window)."""
    r = np.asarray(iq, dtype=np.complex128)
    if len(r) < 2 * L + 1:
        return {"P": np.zeros(0), "R": np.zeros(0), "M": np.zeros(0)}
    prod = np.conj(r[:-L]) * r[L:]
    cs = np.concatenate([[0], np.cumsum(prod)])
    P = cs[L:] - cs[:-L]
    en = np.abs(r[L:]) ** 2
    ce = np.concatenate([[0], np.cumsum(en)])
    R = ce[L:] - ce[:-L]
    n = min(len(P), len(R))
    P, R = P[:n], R[:n]
    return {"P": P, "R": R, "M": np.abs(P) ** 2 / np.maximum(R, 1e-12) ** 2}


def sync_report(events: list[dict], truth_starts: list[float], cfo_true_hz: float, tol: float = 2000) -> dict:
    """Match detection events to the true packet starts (nearest within tol samples) and compute errors.
    Each event needs sync_start_est and cfo_hz_est."""
    out = {"packets_true": len(truth_starts), "detections": len(events), "matches": [], "false_alarms": 0}
    used = set()
    for e in events:
        d = [abs(e["sync_start_est"] - t) for t in truth_starts]
        k = int(np.argmin(d)) if d else -1
        if k >= 0 and d[k] <= tol and k not in used:
            used.add(k)
            out["matches"].append({"packet": k, "timing_error": float(e["sync_start_est"] - truth_starts[k]),
                                   "cfo_est_hz": float(e["cfo_hz_est"]), "cfo_error_hz": float(e["cfo_hz_est"] - cfo_true_hz)})
        else:
            out["false_alarms"] += 1
    out["missed"] = len(truth_starts) - len(used)
    if out["matches"]:
        out["timing_error_abs_max"] = float(max(abs(m["timing_error"]) for m in out["matches"]))
        out["cfo_error_abs_max_hz"] = float(max(abs(m["cfo_error_hz"]) for m in out["matches"]))
    return out
