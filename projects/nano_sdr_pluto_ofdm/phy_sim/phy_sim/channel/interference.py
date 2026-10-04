"""Interference injection (TZ section 8): tone / wideband noise / user supplied IQ, scaled to a signal-to-interference ratio."""
import numpy as np


def add_interference(x: np.ndarray, cfg: dict, fs: float, rng: np.random.Generator) -> np.ndarray:
    kind = cfg.get("type", "tone").lower()
    n = len(x)
    nz = np.abs(x) > 0
    sig_p = float(np.mean(np.abs(x[nz]) ** 2)) if nz.any() else 1.0
    if kind == "tone":
        t = np.arange(n) / fs
        i = np.exp(2j * np.pi * float(cfg.get("freq_hz", 1e6)) * t)
    elif kind == "noise":
        i = (rng.standard_normal(n) + 1j * rng.standard_normal(n)) / np.sqrt(2)
    elif kind == "iq":
        src = np.load(cfg["path"]).astype(np.complex128)
        i = np.resize(src, n)
    else:
        raise ValueError(f"unknown interference type '{kind}'")
    i_p = float(np.mean(np.abs(i) ** 2))
    scale = np.sqrt(sig_p / (10 ** (float(cfg.get("sir_db", 10.0)) / 10)) / i_p)
    return x + scale * i
