"""ТЗ 004, item 3 (diagnostics, model only): is MAX RANGE limited by the decoder or by the packet detector?

The Schmidl-Cox detector of the RTL fires when |P| > R / 2 (correlation against window energy), i.e. only for SNR > 0 dB per sample. MAX RANGE
decodes near 1 dB, so missed detections and decoding failures overlap. The experiment repeats the PER curve of MAX RANGE with the RTL
threshold and with |P| > R / 4 (a model-only knob, rx.det_shift = 2; NOT implemented in RTL), for the baseline and for Patch B.
Output: results/rxenh/det.json    usage: python experiments/rxenh_det.py [--procs N] [--quick]"""
from __future__ import annotations

import argparse
import json
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402
from rxenh_study import CHANNELS, pmap, wilson  # noqa: E402

CASES = {"det R/2 (RTL), baseline": (1, {}), "det R/2 (RTL), Patch B": (1, {"ua": True, "ca": True}),
         "det R/4 (model), baseline": (2, {}), "det R/4 (model), Patch B": (2, {"ua": True, "ca": True})}


def one(job):
    cid, case, snr, seed, npk = job
    sh, opt = CASES[case]
    cfg = build_config({"experiment": {"n_packets": npk, "seed": seed, "packet_gap": 12000, "lead_samples": 2000}, "payload": {"nsyms": 4},
                        "phy": {"mode": "max_range", **opt}, "rx": {"det_shift": sh}, "channel": {"snr_db": snr, **CHANNELS[cid][1]}})
    try:
        m = run_experiment(cfg, outdir=None, plots=False).metrics
        tx = m["packets_transmitted"]
        return {"tx": tx, "lost": min(tx, m.get("packets_lost", 0)), "bad": min(tx, m.get("packets_corrupted", 0) + m.get("packets_lost", 0)),
                "false": m.get("false_detections", 0) or 0}
    except Exception:  # noqa: BLE001
        return {"tx": npk, "lost": npk, "bad": npk, "false": 0}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, default=4)
    ap.add_argument("--quick", action="store_true")
    a = ap.parse_args()
    runs = 3 if a.quick else 40
    jobs = [(cid, case, float(snr), 31000 + 17 * r + int(round(snr * 10)) * 131, 10) for cid in ("awgn", "mp3") for case in CASES
            for snr in np.arange(-1.0 if cid == "awgn" else 0.0, (2.51 if cid == "awgn" else 3.51), 0.5) for r in range(runs)]
    print(len(jobs), "runs", flush=True)
    t0 = time.time()
    with Pool(a.procs) as pool:
        res = pmap(pool, one, jobs, "detector")
    by = {}
    for j, r in zip(jobs, res):
        by.setdefault(j[:3], []).append(r)
    out = {"nsyms": 4, "mode": "max_range", "curves": {}}
    for (cid, case, snr), rs in sorted(by.items()):
        tx = sum(r["tx"] for r in rs); bad = sum(r["bad"] for r in rs)
        out["curves"].setdefault(cid, {}).setdefault(case, []).append({"x": snr, "packets": tx, "errors": bad, "per": bad / tx, "ci": list(wilson(bad, tx)),
                                                                        "lost": sum(r["lost"] for r in rs) / tx})
    Path("results/rxenh").mkdir(parents=True, exist_ok=True)
    Path("results/rxenh/det.json").write_text(json.dumps(out, indent=1))
    print("done", round(time.time() - t0), "s")


if __name__ == "__main__":
    main()
