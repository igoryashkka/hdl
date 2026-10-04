"""Carrier frequency offset (TZ section 8)."""
import numpy as np

from .. import refs


def apply_cfo(x: np.ndarray, cfo_hz: float, phase0_deg: float = 0.0, fs: float = refs.FS) -> np.ndarray:
    n = np.arange(len(x))
    return x * np.exp(1j * (2 * np.pi * cfo_hz * n / fs + np.deg2rad(phase0_deg)))
