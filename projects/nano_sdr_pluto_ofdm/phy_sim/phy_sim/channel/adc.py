"""ADC model: AGC (scale to the target rms), DC offset, quantisation, clipping (TZ section 8)."""
import numpy as np


def apply_adc(x: np.ndarray, cfg: dict):
    """Returns (adc_complex_int, info). The scale models the AD9361 AGC: the stream rms is set to cfg['rms'] LSB."""
    bits = int(cfg.get("bits", 12))
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    nz = np.abs(x) > 0
    rms = np.sqrt(np.mean(np.abs(x[nz]) ** 2)) if nz.any() else 1.0
    scale = float(cfg.get("rms", 600.0)) / rms
    y = x * scale + (float(cfg.get("dc_offset_i", 0.0)) + 1j * float(cfg.get("dc_offset_q", 0.0)))
    yi, yq = np.round(y.real), np.round(y.imag)
    clipped = float(np.mean((yi < lo) | (yi > hi) | (yq < lo) | (yq > hi)))
    if cfg.get("clip", True):
        yi, yq = np.clip(yi, lo, hi), np.clip(yq, lo, hi)
    return (yi + 1j * yq), {"scale": scale, "clipped_fraction": clipped, "bits": bits}
