"""Scenarios (YAML) and parameter sweeps (TZ sections 7, 19)."""
from __future__ import annotations

import itertools
from pathlib import Path

import numpy as np

from .config import build_config, load_yaml, set_path


def load_scenario(path: str | Path) -> dict:
    """Loads a scenario file. Top-level keys: the config sections (experiment, tx, rx, channel, criteria, ...) plus an optional
    `sweep` block and `trials` (repetitions per point, different seeds)."""
    raw = load_yaml(path)
    raw.setdefault("experiment", {}).setdefault("name", Path(path).stem)
    return raw


def _values(spec) -> list:
    if isinstance(spec, dict):
        if "values" in spec:
            return list(spec["values"])
        start, stop, step = spec["start"], spec["stop"], spec["step"]
        n = int(round((stop - start) / step)) + 1
        return [float(v) if isinstance(v, (float, np.floating)) else v for v in np.linspace(start, stop, n)]
    return list(spec)


def expand_sweep(raw: dict) -> list[tuple[dict, dict]]:
    """Returns [(point, config)] for the cartesian product of the sweep parameters (a single point if there is no sweep)."""
    sweep = raw.get("sweep") or {}
    base = {k: v for k, v in raw.items() if k != "sweep"}
    if not sweep:
        return [({}, build_config(base))]
    names = list(sweep)
    out = []
    for combo in itertools.product(*[_values(sweep[n]) for n in names]):
        cfg = build_config(base)
        point = {}
        for n, v in zip(names, combo):
            v = v.item() if hasattr(v, "item") else v
            set_path(cfg, n, v)
            point[n] = v
        out.append((point, cfg))
    return out
