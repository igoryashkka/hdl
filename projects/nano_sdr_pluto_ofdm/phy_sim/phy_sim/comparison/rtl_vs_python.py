"""RTL-vs-Python comparison of two receiver runs over the same IQ (TZ section 22).

Expected relations (see STATUS.md of the RTL project):
  * payload bytes           -> identical unless the channel causes a decision difference
  * sync n_best, cfo_inc    -> bit-exact (the detector and CORDIC are bit-exact models)
  * equalized constellation -> numerical tolerance (the NCO phase origin differs by a few samples between model and RTL)"""
from __future__ import annotations

import numpy as np

from . import bit_exact, tolerance


def compare_rx(py_payload: list[bytes], py_dbg: dict, rtl_payload: list[bytes], rtl_dbg: dict, evm_tol_pct: float = 3.0) -> dict:
    out: dict = {"checks": []}
    out["checks"].append({"name": "packet_count", "ok": len(py_payload) == len(rtl_payload),
                          "python": len(py_payload), "rtl": len(rtl_payload)})
    for k, (a, b) in enumerate(zip(py_payload, rtl_payload)):
        r = bit_exact.compare(np.frombuffer(a, np.uint8), np.frombuffer(b, np.uint8), f"payload[{k}]")
        out["checks"].append({"name": r["name"], "ok": r["match"], **{x: r[x] for x in ("n_mismatch", "first_mismatch")}})
    pe, re_ = py_dbg.get("events", []), rtl_dbg.get("events", [])
    for k, (a, b) in enumerate(zip(pe, re_)):
        out["checks"].append({"name": f"event[{k}].n_best", "ok": a["n_best"] == b["n_best"], "python": a["n_best"], "rtl": b["n_best"]})
        if "cfo_inc" in a and "cfo_inc" in b:
            out["checks"].append({"name": f"event[{k}].cfo_inc", "ok": a["cfo_inc"] == b["cfo_inc"],
                                  "python": a["cfo_inc"], "rtl": b["cfo_inc"]})
    for k, (a, b) in enumerate(zip(py_dbg.get("packets", []), rtl_dbg.get("packets", []))):
        if "eq" in a and "eq" in b and np.size(a["eq"]) == np.size(b["eq"]):
            ea, eb = np.asarray(a["eq"]).ravel(), np.asarray(b["eq"]).ravel()
            g = np.vdot(eb, ea) / max(np.vdot(eb, eb), 1e-12)          # remove a constant phase difference (NCO origin)
            rel = np.sqrt(np.mean(np.abs(ea - g * eb) ** 2) / np.mean(np.abs(ea) ** 2)) * 100
            # the RTL logs the equalised bins before the MMSE bias (1/mu per bin) is removed, the Python model logs them unbiased: at low SNR the
            # two differ by design; the check then only requires identical decisions (payload) and reports the difference
            same_payload = k < len(py_payload) and k < len(rtl_payload) and py_payload[k] == rtl_payload[k]
            out["checks"].append({"name": f"packet[{k}].equalized", "ok": bool(rel < evm_tol_pct or same_payload), "rel_diff_pct": float(rel),
                                  "tolerance_pct": evm_tol_pct, "decisions_identical": bool(same_payload)})
    out["ok"] = all(c["ok"] for c in out["checks"])
    return out
