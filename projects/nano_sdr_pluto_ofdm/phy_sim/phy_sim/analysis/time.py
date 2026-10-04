"""Time-domain plots: I(t), Q(t), |IQ(t)|, phase(t) (TZ section 12)."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from .. import refs  # noqa: E402


def plot_waveform(iq: np.ndarray, path: str, fs: float = refs.FS, start: int = 0, count: int = 6000, markers: dict | None = None,
                  title: str = "waveform") -> str:
    x = np.asarray(iq)[start:start + count]
    t = (np.arange(len(x)) + start) / fs * 1e6
    fig, ax = plt.subplots(4, 1, figsize=(10, 7), sharex=True)
    ax[0].plot(t, x.real, lw=0.6); ax[0].set_ylabel("I")
    ax[1].plot(t, x.imag, lw=0.6, color="C1"); ax[1].set_ylabel("Q")
    ax[2].plot(t, np.abs(x), lw=0.6, color="C2"); ax[2].set_ylabel("|IQ|")
    ax[3].plot(t, np.unwrap(np.angle(x)), lw=0.6, color="C3"); ax[3].set_ylabel("phase [rad]"); ax[3].set_xlabel("time [us]")
    for name, idx in (markers or {}).items():
        if start <= idx < start + count:
            for a in ax:
                a.axvline(idx / fs * 1e6, color="k", ls="--", lw=0.8)
            ax[0].text(idx / fs * 1e6, ax[0].get_ylim()[1] * 0.9, name, rotation=90, va="top", fontsize=7)
    ax[0].set_title(title)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return path
