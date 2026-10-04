"""Spectrum: PSD, occupied bandwidth, subcarrier power (TZ section 12)."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from .. import refs  # noqa: E402
from .statistics import occupied_bandwidth_hz, psd  # noqa: E402


def plot_spectrum(series: dict[str, np.ndarray], path: str, fs: float = refs.FS, title: str = "PSD") -> str:
    fig, ax = plt.subplots(figsize=(10, 4.5))
    for name, iq in series.items():
        f, p = psd(iq, fs)
        ax.plot(f / 1e6, 10 * np.log10(np.maximum(p, 1e-20)), lw=0.8,
                label=f"{name} (OBW99 {occupied_bandwidth_hz(iq, fs) / 1e6:.2f} MHz)")
    ax.set_xlabel("frequency [MHz]"); ax.set_ylabel("PSD [dB/Hz]"); ax.grid(alpha=0.3); ax.legend(fontsize=8); ax.set_title(title)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path


def subcarrier_power_db(iq: np.ndarray, body_starts: list[int]) -> np.ndarray:
    """Mean power per FFT bin (dB) over the given symbol bodies."""
    n = refs.N_FFT
    acc, cnt = np.zeros(n), 0
    for s in body_starts:
        if 0 <= s and s + n <= len(iq):
            acc += np.abs(np.fft.fft(iq[s:s + n])) ** 2
            cnt += 1
    if not cnt:
        return np.zeros(n)
    return 10 * np.log10(np.maximum(acc / cnt, 1e-20))
