"""OFDM-specific plots: subcarrier power, pilot values, cyclic prefix correlation, FFT bins (TZ section 12)."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from .. import refs  # noqa: E402
from .spectrum import subcarrier_power_db  # noqa: E402


def cp_correlation(iq: np.ndarray, start: int, n_sym: int = 1) -> np.ndarray:
    """Normalised correlation between the cyclic prefix and the symbol tail for candidate symbol starts around `start`."""
    cp, n, s = refs.P.CP_LEN, refs.N_FFT, refs.SYM_LEN
    out = []
    for d in range(-200, 201):
        a = start + d
        if a < 0 or a + s > len(iq):
            out.append(0.0)
            continue
        x = iq[a:a + cp]
        y = iq[a + n:a + n + cp]
        out.append(abs(np.vdot(x, y)) / max(np.sqrt(np.vdot(x, x).real * np.vdot(y, y).real), 1e-12))
    return np.array(out)


def plot_ofdm(rx_iq: np.ndarray, body_starts: list[int], fft_data: np.ndarray | None, path: str,
              cp_start: int | None = None) -> str:
    fig, ax = plt.subplots(2, 2, figsize=(11, 7))
    p = subcarrier_power_db(rx_iq, body_starts)
    k = np.arange(refs.N_FFT)
    k = np.where(k > refs.N_FFT // 2, k - refs.N_FFT, k)
    o = np.argsort(k)
    ax[0, 0].plot(k[o], p[o], lw=0.7); ax[0, 0].set_title("subcarrier power (RX, mean over symbols)")
    ax[0, 0].set_xlabel("bin"); ax[0, 0].set_ylabel("dB"); ax[0, 0].grid(alpha=0.3)
    if fft_data is not None and np.size(fft_data):
        d = np.asarray(fft_data)
        d = d if d.ndim == 2 else d[None]
        pil = d[:, refs.rx_fixed_ref.PILOT_S] if d.shape[1] == refs.P.NUM_ACTIVE_SC else None
        if pil is not None:
            ax[0, 1].plot(np.abs(pil[0]), ".-", lw=0.6); ax[0, 1].set_title("|pilot| after FFT (symbol 0, before equalizer)")
            ax[1, 0].plot(np.unwrap(np.angle(pil[0])), ".-", lw=0.6); ax[1, 0].set_title("pilot phase (symbol 0)")
        ax[1, 1].plot(np.abs(d[0]), lw=0.6); ax[1, 1].set_title("|FFT bins| (active, symbol 0)")
    if cp_start is not None:
        c = cp_correlation(rx_iq, cp_start)
        ax[1, 1].clear()
        ax[1, 1].plot(np.arange(-200, 201), c); ax[1, 1].set_title("CP correlation vs symbol start offset"); ax[1, 1].grid(alpha=0.3)
    for a in ax.ravel():
        a.grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path
