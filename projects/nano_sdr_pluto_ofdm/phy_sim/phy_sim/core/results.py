"""Metrics storage and pass/fail criteria (TZ section 20)."""
from __future__ import annotations

import json
from pathlib import Path

from .trace import jsonable

# criteria key -> (metric path, comparison, label)
_CRITERIA = {
    "max_ber": ("ber", "<=", "BER"),
    "max_ser": ("ser", "<=", "SER"),
    "max_per": ("per", "<=", "PER"),
    "max_evm_percent": ("evm_rms_pct", "<=", "EVM rms [%]"),
    "max_evm_peak_percent": ("evm_peak_pct", "<=", "EVM peak [%]"),
    "min_mer_db": ("mer_db", ">=", "MER [dB]"),
    "max_cfo_error_hz": ("cfo_error_abs_max_hz", "<=", "CFO error [Hz]"),
    "max_timing_error_samples": ("timing_error_abs_max", "<=", "timing error [samples]"),
    "max_channel_est_mse_db": ("channel_est_mse_db", "<=", "channel est. MSE [dB]"),
    "min_packets_received": ("packets_received", ">=", "packets received"),
    "max_sync_failures": ("sync_failures", "<=", "sync failures"),
    "max_papr_db": ("papr_db", "<=", "PAPR [dB]"),
}


def evaluate_criteria(metrics: dict, criteria: dict) -> tuple[bool, list[str]]:
    """Returns (passed, human readable lines like 'BER = 0 <= 1e-05 ok')."""
    lines, ok = [], True
    for key, limit in (criteria or {}).items():
        if key not in _CRITERIA:
            lines.append(f"unknown criterion '{key}' (ignored)")
            continue
        m, op, label = _CRITERIA[key]
        v = metrics.get(m)
        if v is None:
            ok = False
            lines.append(f"FAIL {label}: not measured")
            continue
        good = (v <= limit) if op == "<=" else (v >= limit)
        ok &= bool(good)
        lines.append(f"{'ok  ' if good else 'FAIL'} {label} = {v:.6g} {op} {limit}")
    return ok, lines


def save_metrics(path: str | Path, metrics: dict) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(jsonable(metrics), f, indent=2)


def load_metrics(path: str | Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)
