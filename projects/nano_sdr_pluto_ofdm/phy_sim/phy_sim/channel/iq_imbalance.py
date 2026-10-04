"""IQ gain/phase imbalance: y = alpha x + beta conj(x) (TZ section 8)."""
import numpy as np


def apply_iq_imbalance(x: np.ndarray, gain_db: float = 0.0, phase_deg: float = 0.0) -> np.ndarray:
    g = 10 ** (gain_db / 20)
    ph = np.deg2rad(phase_deg)
    alpha = (1 + g * np.exp(-1j * ph)) / 2
    beta = (1 - g * np.exp(1j * ph)) / 2
    return alpha * x + beta * np.conj(x)
