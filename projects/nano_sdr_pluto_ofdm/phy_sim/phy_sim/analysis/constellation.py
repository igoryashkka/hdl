"""Constellation plots: TX / RX (FFT, pre-equalizer) / equalized (TZ section 12)."""
from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402


def plot_constellations(panels: dict[str, np.ndarray], path: str, max_points: int = 6000) -> str:
    n = max(1, len(panels))
    fig, ax = plt.subplots(1, n, figsize=(4.2 * n, 4.2), squeeze=False)
    for a, (name, pts) in zip(ax[0], panels.items()):
        p = np.asarray(pts).ravel()
        if p.size > max_points:
            p = p[np.linspace(0, p.size - 1, max_points).astype(int)]
        a.scatter(p.real, p.imag, s=3, alpha=0.5)
        lim = np.max(np.abs(np.concatenate([p.real, p.imag]))) * 1.1 if p.size else 1
        a.set_xlim(-lim, lim); a.set_ylim(-lim, lim); a.set_aspect("equal"); a.grid(alpha=0.3); a.set_title(name, fontsize=9)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path
