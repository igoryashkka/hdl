"""Baseband channel model for system tests (float): multipath, CFO, AWGN, leading noise (unknown packet start)."""
import numpy as np
from phy_params import SAMPLE_RATE_HZ


def apply_channel(x, snr_db=None, cfo_hz=0.0, paths=((0, 1.0),), lead=0, trail=0, phase0=0.0, seed=1, drift_hz_per_s=0.0):
    """x: complex baseband (float). paths: ((delay_samples, complex_gain), ...). snr_db is relative to the signal power
    in the active part of x (before multipath normalisation). Returns complex array (lead noise + frame + trail noise)."""
    rng = np.random.default_rng(seed)
    x = np.asarray(x, dtype=np.complex128)
    sig_pow = np.mean(np.abs(x) ** 2)
    maxd = max(d for d, _ in paths)
    y = np.zeros(len(x) + maxd, dtype=np.complex128)
    for d, g in paths:
        y[d:d + len(x)] += g * x
    y = np.concatenate([np.zeros(lead, complex), y, np.zeros(trail, complex)])
    n = np.arange(len(y))
    ph = 2 * np.pi * cfo_hz * n / SAMPLE_RATE_HZ + phase0
    if drift_hz_per_s:
        ph += np.pi * drift_hz_per_s * (n / SAMPLE_RATE_HZ) ** 2
    y = y * np.exp(1j * ph)
    if snr_db is not None:
        npow = sig_pow / (10 ** (snr_db / 10))
        y = y + np.sqrt(npow / 2) * (rng.standard_normal(len(y)) + 1j * rng.standard_normal(len(y)))
    return y
