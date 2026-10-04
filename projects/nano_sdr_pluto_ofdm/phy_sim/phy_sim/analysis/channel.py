"""Channel estimation analysis (TZ section 14): H_true vs H_est."""
from __future__ import annotations

import numpy as np

from .. import refs


def estimation_error(h_est: np.ndarray, h_true: np.ndarray, bins: np.ndarray | None = None, search: float = 100.0) -> dict:
    """The receiver estimate contains an arbitrary complex gain (TX/RX scaling, phase) and the linear phase of the FFT window
    placement. Both are removed with the least-squares optimum before the error is computed:
    h_est ~ c * h_true * exp(-j*2*pi*k*tau/N); returns the normalised MSE (dB) and the fitted tau (samples)."""
    bins = refs.rx_ref.ACTIVE_BINS if bins is None else np.asarray(bins)
    k = np.where(bins > refs.N_FFT // 2, bins - refs.N_FFT, bins)
    he = np.asarray(h_est, dtype=complex)
    ht = np.asarray(h_true, dtype=complex)
    best = (np.inf, 0.0, 1.0 + 0j)
    for tau in np.arange(-search, search + 0.25, 0.25):
        m = ht * np.exp(-2j * np.pi * k * tau / refs.N_FFT)
        c = np.vdot(m, he) / np.vdot(m, m)
        err = np.sum(np.abs(he - c * m) ** 2) / np.sum(np.abs(he) ** 2)
        if err < best[0]:
            best = (err, tau, c)
    mse, tau, c = best
    fit = c * ht * np.exp(-2j * np.pi * k * tau / refs.N_FFT)
    return {"mse_db": float(10 * np.log10(max(mse, 1e-12))), "tau_samples": float(tau), "gain": complex(c),
            "h_true_fit": fit, "abs_err_rms": float(np.sqrt(np.mean(np.abs(he - fit) ** 2)))}
