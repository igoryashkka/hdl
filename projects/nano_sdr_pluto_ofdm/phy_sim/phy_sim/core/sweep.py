"""Batch experiments (parameter sweeps) with heatmaps (TZ section 19)."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from ..core.config import build_config
from ..core.experiment import run_experiment
from ..core.results import save_metrics
from ..core.scenario import expand_sweep


def run_sweep(raw: dict, outdir: str | Path, trials: int | None = None, progress=print, keep_runs: bool = False) -> dict:
    """Runs the cartesian product of raw['sweep'] (each point `trials` times with different seeds) and aggregates BER / PER /
    EVM / sync-failure statistics. Returns the aggregate dictionary (also stored as sweep.json + heatmaps)."""
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    points = expand_sweep(raw)
    trials = int(trials if trials is not None else raw.get("trials", 1))
    rows = []
    for pi, (point, cfg) in enumerate(points):
        agg = {"ber": [], "per": [], "ser": [], "evm_rms_pct": [], "sync_fail": [], "cfo_err": [], "timing_err": [], "passed": []}
        for t in range(trials):
            c = json.loads(json.dumps(cfg))
            c["experiment"]["seed"] = int(c["experiment"].get("seed", 1)) + 1000 * t + 17 * pi
            run_dir = out / f"point_{pi:03d}_t{t}" if keep_runs else None
            res = run_experiment(c, outdir=run_dir, plots=False if not keep_runs else None)
            m = res.metrics
            agg["ber"].append(m["ber"]); agg["per"].append(m["per"]); agg["ser"].append(m["ser"])
            if "evm_rms_pct" in m:
                agg["evm_rms_pct"].append(m["evm_rms_pct"])
            agg["sync_fail"].append(m.get("sync_failures", 0) > 0 or m["packets_received"] < m["packets_transmitted"])
            if "cfo_error_abs_max_hz" in m:
                agg["cfo_err"].append(m["cfo_error_abs_max_hz"])
            if "timing_error_abs_max" in m:
                agg["timing_err"].append(m["timing_error_abs_max"])
            agg["passed"].append(res.passed)
        row = {"point": point, "trials": trials, "ber": float(np.mean(agg["ber"])), "per": float(np.mean(agg["per"])),
               "ser": float(np.mean(agg["ser"])), "evm_rms_pct": float(np.mean(agg["evm_rms_pct"])) if agg["evm_rms_pct"] else None,
               "sync_failure_rate": float(np.mean(agg["sync_fail"])),
               "cfo_error_max_hz": float(np.max(agg["cfo_err"])) if agg["cfo_err"] else None,
               "timing_error_max": float(np.max(agg["timing_err"])) if agg["timing_err"] else None,
               "pass_rate": float(np.mean(agg["passed"]))}
        rows.append(row)
        progress(f"[{pi + 1}/{len(points)}] {point} BER={row['ber']:.3g} PER={row['per']:.3g} EVM={row['evm_rms_pct']} "
                 f"syncfail={row['sync_failure_rate']:.2f}")
    result = {"name": raw["experiment"]["name"], "rows": rows}
    save_metrics(out / "sweep.json", result)
    _plots(result, raw.get("sweep") or {}, out)
    return result


def _plots(result: dict, sweep: dict, out: Path) -> None:
    from ..report.plots import plot_heatmap
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    names = list(sweep)
    rows = result["rows"]
    if not names:
        return
    if len(names) == 1:
        x = [r["point"][names[0]] for r in rows]
        fig, ax = plt.subplots(1, 3, figsize=(14, 4))
        ax[0].semilogy(x, np.maximum([r["ber"] for r in rows], 1e-7), "o-"); ax[0].set_title("BER")
        ax[1].semilogy(x, np.maximum([r["per"] for r in rows], 1e-4), "o-"); ax[1].set_title("PER")
        ax[2].plot(x, [r["evm_rms_pct"] if r["evm_rms_pct"] is not None else np.nan for r in rows], "o-"); ax[2].set_title("EVM rms [%]")
        for a in ax:
            a.set_xlabel(names[0]); a.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(out / "sweep_curves.png", dpi=110); plt.close(fig)
        return
    xs = sorted({r["point"][names[0]] for r in rows})
    ys = sorted({r["point"][names[1]] for r in rows})
    for key, title, log in (("ber", "BER", True), ("per", "PER", False), ("evm_rms_pct", "EVM rms [%]", False),
                            ("sync_failure_rate", "sync failure rate", False)):
        grid = np.full((len(ys), len(xs)), np.nan)
        for r in rows:
            v = r[key]
            grid[ys.index(r["point"][names[1]]), xs.index(r["point"][names[0]])] = np.nan if v is None else v
        plot_heatmap(grid, xs, ys, title, str(out / f"heatmap_{key}.png"), names[0], names[1], log=log)
