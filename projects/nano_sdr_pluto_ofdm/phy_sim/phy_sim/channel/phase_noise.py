"""Oscillator phase noise: Wiener process (Lorentzian linewidth) + optional white phase jitter (TZ section 8)."""
import numpy as np


def apply_phase_noise(x: np.ndarray, cfg: dict, fs: float, rng: np.random.Generator):
    n = len(x)
    ph = np.zeros(n)
    lw = float(cfg.get("linewidth_hz", 0.0))
    if lw > 0:
        ph += np.cumsum(rng.standard_normal(n) * np.sqrt(2 * np.pi * lw / fs))
    std = float(cfg.get("std_rad", 0.0))
    if std > 0:
        ph += rng.standard_normal(n) * std
    return x * np.exp(1j * ph), ph
