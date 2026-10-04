"""Replay of a captured IQ trace without re-simulating the channel (TZ section 11)."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from ..core.config import build_config, deep_update
from ..core.experiment import ExperimentResult, run_experiment


def load_capture(path: str | Path):
    """path: a capture directory (rx.iq + metadata.json), an .iq file (int16 interleaved) or an .npy/.npz complex array."""
    p = Path(path)
    meta = {}
    if p.is_dir():
        meta_file = p / "metadata.json"
        if meta_file.exists():
            meta = json.loads(meta_file.read_text(encoding="utf-8"))
        p = p / "rx.iq"
    elif (p.parent / "metadata.json").exists():
        meta = json.loads((p.parent / "metadata.json").read_text(encoding="utf-8"))
    if p.suffix == ".npy":
        iq = np.load(p)
    elif p.suffix == ".npz":
        z = np.load(p)
        iq = z[list(z.files)[0]]
    else:
        raw = np.fromfile(p, dtype=np.int16)
        iq = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    return iq, meta


def replay(path: str | Path, outdir: str | Path | None = None, overrides: dict | None = None) -> ExperimentResult:
    """Runs only the RX (and the analysis against the stored ground truth when metadata is available)."""
    iq, meta = load_capture(path)
    cfg = build_config(deep_update(meta.get("config", {}), overrides or {}))
    cfg["channel"]["adc"]["enabled"] = False
    truth = {"delay_samples": meta.get("ground_truth", {}).get("timing_offset", 0.0),
             "cfo_hz": meta.get("ground_truth", {}).get("cfo_hz", 0.0)}
    truth.update(meta.get("ground_truth", {}).get("channel", {}) or {})
    return run_experiment(cfg, outdir=outdir, rx_iq_override=iq, truth_override=truth)
