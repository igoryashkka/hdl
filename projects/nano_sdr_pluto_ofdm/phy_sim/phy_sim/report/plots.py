"""Plot orchestration for one experiment and heatmaps for sweeps (TZ sections 12, 13, 14, 19)."""
from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from .. import refs  # noqa: E402
from ..analysis import constellation, ofdm, spectrum, time as atime, waterfall  # noqa: E402


def plot_synchronization(rx_dbg: dict, gt: dict, path: str, events: list[dict]) -> str | None:
    sm = rx_dbg.get("sync_metric") or {}
    if not sm:
        return None
    M = np.asarray(sm["M"])
    fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    Rv = np.asarray(sm["R"])
    Mp = np.where(Rv > 0.02 * np.max(Rv), np.minimum(M, 1.5), np.nan)       # hide the 0/0 region of the silent tail
    ax[0].plot(Mp, lw=0.8, label="M(n)=|P|^2/R^2"); ax[0].axhline(0.5, color="gray", ls=":", label="threshold 0.5")
    ax[0].set_ylim(-0.05, 1.3)
    for k, t in enumerate(gt["packet_start"]):
        ax[0].axvline(t, color="r", ls="--", lw=1, label="true packet start" if k == 0 else None)
    for k, e in enumerate(events):
        ax[0].axvline(e["sync_start_est"], color="g", ls="-.", lw=1, label="detected start" if k == 0 else None)
    ax[0].set_ylabel("metric"); ax[0].legend(fontsize=8); ax[0].grid(alpha=0.3); ax[0].set_title("Schmidl-Cox timing metric")
    ax[1].plot(np.abs(sm["P"]), lw=0.7, label="|P(n)|"); ax[1].plot(sm["R"], lw=0.7, label="R(n)")
    ax[1].set_xlabel("sample index"); ax[1].legend(fontsize=8); ax[1].grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path


def plot_channel_estimate(gt: dict, path: str) -> str | None:
    hs = gt.get("_h")
    if not hs:
        return None
    h_est, h_fit, e = hs[0]
    k = refs.rx_ref.ACTIVE_BINS
    kk = np.where(k > refs.N_FFT // 2, k - refs.N_FFT, k)
    o = np.argsort(kk)
    fig, ax = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    ax[0].plot(kk[o], np.abs(h_fit)[o], label="|H_true| (fitted gain/delay)"); ax[0].plot(kk[o], np.abs(h_est)[o], lw=0.8, label="|H_est| (RX)")
    ax[0].set_ylabel("magnitude"); ax[0].legend(fontsize=8); ax[0].grid(alpha=0.3)
    ax[0].set_title(f"channel estimation: MSE {e['mse_db']:.1f} dB (tau {e['tau_samples']:+.2f} samples)")
    ax[1].plot(kk[o], np.unwrap(np.angle(h_fit)[o]), label="phase H_true"); ax[1].plot(kk[o], np.unwrap(np.angle(h_est)[o]), lw=0.8, label="phase H_est")
    ax[1].set_xlabel("subcarrier"); ax[1].set_ylabel("phase [rad]"); ax[1].legend(fontsize=8); ax[1].grid(alpha=0.3)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path


def make_plots(res, plots_dir: Path) -> dict[str, str]:
    plots_dir.mkdir(parents=True, exist_ok=True)
    out: dict[str, str] = {}
    gt, dbg = res.truth, res.rx_debug
    iq_tx, iq_ch = res._iq_tx, res._iq_ch
    marks = {}
    if gt["packet_start"]:
        marks["packet start"] = int(gt["packet_start"][0])
        marks["LTS"] = int(gt["lts_start"][0])
    start = max(0, int(gt["packet_start"][0]) - 400) if gt["packet_start"] else 0
    out["waveform"] = atime.plot_waveform(iq_ch, str(plots_dir / "waveform.png"), start=start, count=6500, markers=marks,
                                          title="channel output (ADC samples)")
    out["spectrum"] = spectrum.plot_spectrum({"TX": iq_tx, "RX (ADC)": iq_ch}, str(plots_dir / "spectrum.png"))
    out["waterfall"] = waterfall.plot_waterfall(iq_ch, str(plots_dir / "waterfall.png"))
    events = [e for e in dbg.get("events", []) if e.get("status", "ok") == "ok"]
    p = plot_synchronization(dbg, gt, str(plots_dir / "synchronization.png"), events)
    if p:
        out["synchronization"] = p
    panels = {}
    if gt.get("tx_symbols"):
        panels["TX (ideal)"] = gt["tx_symbols"][0]
    pk0 = (dbg.get("packets") or [None])[0]
    if pk0 is not None and "fft_data" in pk0 and np.size(pk0["fft_data"]):
        d = np.asarray(pk0["fft_data"])[:, refs.rx_fixed_ref.DATA_S] if np.ndim(pk0["fft_data"]) == 2 else np.asarray(pk0["fft_data"])
        panels["RX FFT bins (before equalizer)"] = d
    if "_eq_all" in gt:
        panels["equalized"] = gt["_eq_all"]
    if panels:
        out["constellation"] = constellation.plot_constellations(panels, str(plots_dir / "constellation.png"))
    p = plot_channel_estimate(gt, str(plots_dir / "channel_estimate.png"))
    if p:
        out["channel_estimate"] = p
    bodies = [int(round(s)) + refs.P.CP_LEN for sl in gt["data_symbol_starts"][:1] for s in sl]
    if bodies:
        fft0 = pk0["fft_data"] if (pk0 is not None and "fft_data" in pk0) else None
        out["ofdm"] = ofdm.plot_ofdm(iq_ch, bodies, fft0, str(plots_dir / "ofdm.png"),
                                     cp_start=int(round(gt["data_symbol_starts"][0][0])) if gt["data_symbol_starts"] else None)
    return out


def plot_heatmap(grid: np.ndarray, xs, ys, title: str, path: str, xlabel: str, ylabel: str, fmt: str = "{:.2g}", log: bool = False,
                 cmap: str = "viridis") -> str:
    fig, ax = plt.subplots(figsize=(1.0 + 0.9 * len(xs), 1.2 + 0.55 * len(ys)))
    data = np.array(grid, dtype=float)
    shown = np.log10(np.maximum(data, 1e-7)) if log else data
    im = ax.imshow(shown, aspect="auto", origin="lower", cmap=cmap)
    ax.set_xticks(range(len(xs))); ax.set_xticklabels([str(x) for x in xs], fontsize=8)
    ax.set_yticks(range(len(ys))); ax.set_yticklabels([str(y) for y in ys], fontsize=8)
    ax.set_xlabel(xlabel); ax.set_ylabel(ylabel); ax.set_title(title)
    for i in range(len(ys)):
        for j in range(len(xs)):
            v = data[i, j]
            ax.text(j, i, "n/a" if np.isnan(v) else fmt.format(v), ha="center", va="center", fontsize=7, color="w")
    fig.colorbar(im, ax=ax, label="log10" if log else "")
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)
    return path
