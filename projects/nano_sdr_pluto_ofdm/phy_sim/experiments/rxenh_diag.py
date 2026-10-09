"""ТЗ 004, item 3: diagnostics that decide which further algorithm is worth implementing (ICI cancellation or sparse / delay-domain
channel estimation). Nothing is implemented in RTL here.

Part 1  impairment isolation (bit-exact receiver model, baseline): PER, lost packets, EVM and LDPC iterations at a fixed SNR with the 3-path
        channel alone and with ONE impairment added at a time (CFO, SFO, timing offset, phase noise), then all together.
        If inter-carrier interference limited the receiver, the CFO / phase-noise rows would show it.
Part 2  where is the remaining loss (float link model python/rxenh_proto.py, codeword error rate): today's estimator (LTS, 3-bin smoothing)
        (channels: flat and a 2-path channel with an 11-sample echo) against a delay-domain filtered LS estimate ("wiener": the estimate is restricted to delays -16 .. 160 samples) and perfect channel
        knowledge (genie).
Output: results/rxenh/diag.json
usage: python experiments/rxenh_diag.py [--procs N] [--quick]"""
from __future__ import annotations

import argparse
import json
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim import refs  # noqa: E402
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from rxenh_study import pmap  # noqa: E402

MP3 = [{"delay": 0, "gain_db": 0}, {"delay": 10, "gain_db": -6}, {"delay": 25, "gain_db": -12}]
IMPAIR = {
    "3 paths only": {},
    "+ CFO 4 kHz": {"cfo_hz": 4000},
    "+ CFO 12 kHz": {"cfo_hz": 12000},
    "+ SFO 15 ppm": {"sfo_ppm": 15},
    "+ timing offset 3.4 samples": {"timing_offset": 3, "fractional_delay": 0.4},
    "+ phase noise 50 Hz": {"phase_noise": {"linewidth_hz": 50}},
    "+ phase noise 500 Hz": {"phase_noise": {"linewidth_hz": 500}},
    "all (CFO 4 kHz, SFO, timing, phase noise 50 Hz)": {"cfo_hz": 4000, "sfo_ppm": 15, "timing_offset": 3, "fractional_delay": 0.4, "phase_noise": {"linewidth_hz": 50}},
}
POINTS = {"max_rate": (16.0, 20.0), "max_range": (4.0, 8.0)}


def one(job):
    mode, name, snr, seed, npk = job
    cfg = build_config({"experiment": {"n_packets": npk, "seed": seed, "packet_gap": 12000, "lead_samples": 2000}, "payload": {"nsyms": 4},
                        "phy": {"mode": mode}, "channel": {"snr_db": snr, "multipath": MP3, **IMPAIR[name]}})
    try:
        r = run_experiment(cfg, outdir=None, plots=False)
        m = r.metrics
        return {"tx": m["packets_transmitted"], "lost": m.get("packets_lost", 0), "corr": m.get("packets_corrupted", 0), "evm": m.get("evm_rms_pct"),
                "iters": m.get("ldpc_iterations_mean"), "cfo_err": m.get("cfo_error_abs_max_hz"), "cfo_res": m.get("cfo_residual_estimate_hz_absmax")}
    except Exception as e:  # noqa: BLE001
        return {"tx": npk, "lost": npk, "corr": 0, "evm": None, "iters": None, "cfo_err": None, "cfo_res": None, "err": str(e)[:80]}


def proto(job):
    mode, kind, snr, seed, npk = job
    import rxenh_proto as RP
    r, n = RP.run(mode, snr, kind, nsym=2, npk=npk, seed=seed, variants=("base", "ua", "iter_rel", "wiener", "genie"))
    return {k: v * n for k, v in r.items()}, n


def mean(v):
    v = [x for x in v if x is not None]
    return float(np.mean(v)) if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, default=4)
    ap.add_argument("--quick", action="store_true")
    a = ap.parse_args()
    runs, npk = (2, 5) if a.quick else (30, 10)
    jobs = [(mode, name, snr, 7000 + 13 * r, npk) for mode, snrs in POINTS.items() for snr in snrs for name in IMPAIR for r in range(runs)]
    pj = []
    grid = {0: np.arange(0.0, 5.01, 0.5), 1: np.arange(10.5, 16.01, 0.5)}
    for mode in (0, 1):
        for kind in ("awgn", "2path"):
            for snr in grid[mode]:
                for r in range(2 if a.quick else 12):
                    pj.append((mode, kind, float(snr) + (1.0 if kind == "2path" else 0.0), 100 + r, 10 if a.quick else 25))
    t0 = time.time()
    with Pool(a.procs) as pool:
        res = pmap(pool, one, jobs, "impairments")
        pres = pmap(pool, proto, pj, "estimator")
    out = {"impairments": [], "estimator": [], "packets_per_row": runs * npk}
    by = {}
    for j, r in zip(jobs, res):
        by.setdefault(j[:3], []).append(r)
    for (mode, name, snr), rs in by.items():
        tx = sum(r["tx"] for r in rs)
        out["impairments"].append({"mode": mode, "case": name, "snr_db": snr, "packets": tx, "lost": sum(r["lost"] for r in rs), "corrupted": sum(r["corr"] for r in rs),
                                   "per": (sum(r["lost"] for r in rs) + sum(r["corr"] for r in rs)) / tx, "evm_pct": mean([r["evm"] for r in rs]),
                                   "iters": mean([r["iters"] for r in rs]),
                                   "cfo_error_abs_max_hz": max([r["cfo_err"] for r in rs if r["cfo_err"] is not None], default=None),
                                   "cfo_residual_absmax_hz": max([r["cfo_res"] for r in rs if r["cfo_res"] is not None], default=None)})
    pb = {}
    for j, (e, n) in zip(pj, pres):
        d = pb.setdefault(j[:3], {"n": 0})
        d["n"] += n
        for k, v in e.items():
            d[k] = d.get(k, 0) + v
    for (mode, kind, snr), d in sorted(pb.items()):
        out["estimator"].append({"mode": "max_range" if mode == 0 else "max_rate", "channel": kind, "snr_db": snr, "codewords": d["n"],
                                 **{k: v / d["n"] for k, v in d.items() if k != "n"}})
    p = Path("results/rxenh")
    p.mkdir(parents=True, exist_ok=True)
    (p / "diag.json").write_text(json.dumps(out, indent=1))
    print("done", round(time.time() - t0), "s")


if __name__ == "__main__":
    main()
