"""Experiment configuration: plain dictionaries with defaults (YAML friendly) + a few typed helpers."""
from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import yaml

DEFAULTS: dict[str, Any] = {
    "experiment": {"name": "experiment", "seed": 1, "n_packets": 1, "packet_gap": 12000, "lead_samples": 1200,
                   "trail_samples": 3000},
    "payload": {"nsyms": 2, "pattern": "random"},             # nsyms x 550 bytes per packet (PHY frame granularity)
    "tx": {"backend": "python", "gain": 16384},                # Q2.14, 16384 = 1.0
    "rx": {"backend": "python", "mode": "fixed",               # python modes: fixed (bit-exact RTL model) | float
           "rmin": 262144, "gain_sh": 0, "dc_k": 12, "hold": 9000},
    "channel": {                                              # every impairment is optional
        "snr_db": None, "snr_definition": "sample",            # sample | esn0 | ebn0
        "cfo_hz": 0.0, "sfo_ppm": 0.0, "phase0_deg": 0.0,
        "timing_offset": 0,                                    # integer samples of extra delay
        "fractional_delay": 0.0,                               # 0..1 sample
        "multipath": [],                                       # [{delay: int, gain_db: float, phase_deg: float}]
        "fading": None,                                        # {type: rayleigh|rician, doppler_hz, k_factor_db, delays: [...]}
        "phase_noise": None,                                   # {linewidth_hz} (Wiener) or {std_rad}
        "iq_imbalance": None,                                  # {gain_db, phase_deg}
        "pa": None,                                            # {type: rapp, p_sat, smoothness, am_pm_deg}
        "interference": None,                                  # {type: tone|noise|iq, sir_db, freq_hz, path}
        "adc": {"enabled": True, "bits": 12, "rms": 600.0, "clip": True,
                "dc_offset_i": 0.0, "dc_offset_q": 0.0},
    },
    "rtl": {"vivado_dir": None, "workdir": None, "keep_work": False, "debug": True},
    "criteria": {},
    "report": {"plots": True, "html": True},
}


def deep_update(base: dict, upd: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (upd or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_update(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def load_yaml(path: str | Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def build_config(user: dict | None = None) -> dict:
    """Merge a user dictionary (e.g. loaded from YAML) over the defaults."""
    return deep_update(DEFAULTS, user or {})


def set_path(cfg: dict, dotted: str, value: Any) -> None:
    """cfg['a']['b'] = value for 'a.b'; a bare key is looked up in the sections 'channel', 'rx', 'tx', 'payload'."""
    parts = dotted.split(".")
    if len(parts) == 1:
        for sec in ("channel", "rx", "tx", "payload", "experiment"):
            if parts[0] in cfg.get(sec, {}):
                cfg[sec][parts[0]] = value
                return
        raise KeyError(f"unknown sweep parameter '{dotted}'")
    d = cfg
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    d[parts[-1]] = value
