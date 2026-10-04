"""Rayleigh / Rician tapped-delay-line fading (TZ section 8): every tap is an independent Clarke process."""
import numpy as np

from .doppler import jakes_gain


def apply_fading(x: np.ndarray, cfg: dict, fs: float, rng: np.random.Generator):
    """cfg: type (rayleigh|rician), doppler_hz, k_factor_db (rician: LOS on the first tap), delays [int], powers_db [float].
    Returns (y, taps) where taps = list of (delay, gain_array) used for the ground truth channel response."""
    kind = cfg.get("type", "rayleigh").lower()
    delays = [int(d) for d in cfg.get("delays", [0])]
    powers_db = cfg.get("powers_db", [0.0] * len(delays))
    p = 10 ** (np.asarray(powers_db, float) / 10)
    p = p / p.sum()
    fd = float(cfg.get("doppler_hz", 0.0))
    maxd = max(delays)
    y = np.zeros(len(x) + maxd, dtype=np.complex128)
    taps = []
    for i, (d, pw) in enumerate(zip(delays, p)):
        g = jakes_gain(len(x), fd, fs, rng)
        if kind == "rician" and i == 0:
            k = 10 ** (float(cfg.get("k_factor_db", 6.0)) / 10)
            g = np.sqrt(k / (k + 1)) + np.sqrt(1 / (k + 1)) * g
        g = g * np.sqrt(pw)
        y[d:d + len(x)] += g * x
        taps.append((d, g))
    return y, taps
