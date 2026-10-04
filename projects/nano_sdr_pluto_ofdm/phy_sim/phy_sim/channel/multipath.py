"""Static multipath (tap delay / amplitude / phase) (TZ section 8)."""
import numpy as np


def taps_from_config(taps: list[dict]) -> list[tuple[int, complex]]:
    out = []
    for t in taps:
        g = 10 ** (float(t.get("gain_db", 0.0)) / 20) * np.exp(1j * np.deg2rad(float(t.get("phase_deg", 0.0))))
        out.append((int(t["delay"]), complex(g)))
    return out


def apply_multipath(x: np.ndarray, taps: list[tuple[int, complex]]) -> np.ndarray:
    maxd = max(d for d, _ in taps)
    y = np.zeros(len(x) + maxd, dtype=np.complex128)
    for d, g in taps:
        y[d:d + len(x)] += g * x
    return y


def frequency_response(taps: list[tuple[int, complex]], bins: np.ndarray, n_fft: int) -> np.ndarray:
    """H[k] = sum g_i exp(-j 2 pi k d_i / N) for FFT bin numbers (negative frequencies as k - N)."""
    k = np.where(bins > n_fft // 2, bins - n_fft, bins)
    return sum(g * np.exp(-2j * np.pi * k * d / n_fft) for d, g in taps)
