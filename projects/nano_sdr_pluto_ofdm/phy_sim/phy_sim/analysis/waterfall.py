"""Waterfall (spectrogram): frequency vs time (TZ section 12)."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from scipy import signal  # noqa: E402

from .. import refs  # noqa: E402


def plot_waterfall(iq: np.ndarray, path: str, fs: float = refs.FS, nfft: int = 1024, title: str = "waterfall") -> str:
    f, t, sxx = signal.spectrogram(np.asarray(iq, dtype=np.complex128), fs=fs, nperseg=nfft, noverlap=nfft // 2,
                                   return_onesided=False, mode="psd")
    o = np.argsort(f)
    fig, ax = plt.subplots(figsize=(10, 4.5))
    im = ax.pcolormesh(t * 1e6, f[o] / 1e6, 10 * np.log10(np.maximum(sxx[o], 1e-20)), shading="auto", cmap="viridis")
    ax.set_xlabel("time [us]"); ax.set_ylabel("frequency [MHz]"); ax.set_title(title)
    fig.colorbar(im, ax=ax, label="dB/Hz")
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path
