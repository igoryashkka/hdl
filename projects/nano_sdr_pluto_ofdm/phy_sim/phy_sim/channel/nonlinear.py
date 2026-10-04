"""Nonlinear power amplifier: Rapp AM/AM + AM/PM (TZ section 8)."""
import numpy as np


def apply_pa(x: np.ndarray, cfg: dict) -> np.ndarray:
    """cfg: ibo_db (input back-off relative to the rms level -> saturation amplitude), smoothness p, am_pm_deg (phase at saturation)."""
    nz = np.abs(x) > 0
    rms = np.sqrt(np.mean(np.abs(x[nz]) ** 2)) if nz.any() else 1.0
    a_sat = rms * 10 ** (float(cfg.get("ibo_db", 6.0)) / 20)
    p = float(cfg.get("smoothness", 2.0))
    a = np.abs(x)
    g = 1.0 / (1.0 + (a / a_sat) ** (2 * p)) ** (1.0 / (2 * p))
    pm = np.deg2rad(float(cfg.get("am_pm_deg", 0.0))) * (a ** 2 / (a ** 2 + a_sat ** 2))
    return x * g * np.exp(1j * pm)
