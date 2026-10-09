"""ТЗ 004: Baseline -> Patch A (uncertainty-aware LLR) -> Patch B (A + one code-aided pass), bit-exact Python models of the RTL receivers (python:fixed).

Same channel realisations and payloads for the three configurations (common seeds), fine SNR grid (0.5 dB) around PER = 1 %.
Channels: AWGN, 3-path multipath, and "impaired" = 3 paths + CFO 4 kHz + SFO 15 ppm + timing offset 3.4 samples (+ phase noise 50 Hz).
Output: results/rxenh/study.json  (per curve: points with packets, errors, PER, Wilson 95 % interval, BER, FER, EVM, LDPC iterations, second-pass share).
usage: python experiments/rxenh_study.py [--quick] [--procs N] [--nsyms 4]
       python experiments/rxenh_study.py --refine [--extra 120]   more packets at the SNR points around PER = 1 % of an existing study.json
                                                                  (the same points and seeds for the three configurations), merged into it"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402

MP3 = [{"delay": 0, "gain_db": 0}, {"delay": 10, "gain_db": -6}, {"delay": 25, "gain_db": -12}]
CHANNELS = {
    "awgn": ("AWGN", {}),
    "mp3": ("3 paths (0 / 0.33 / 0.81 us)", {"multipath": MP3}),
    "impaired": ("3 paths + CFO 4 kHz + SFO 15 ppm + timing offset + phase noise 50 Hz",
                 {"multipath": MP3, "cfo_hz": 4000, "sfo_ppm": 15, "timing_offset": 3, "fractional_delay": 0.4, "phase_noise": {"linewidth_hz": 50}}),
}
CONFIGS = {"baseline": {}, "patch_a": {"ua": True}, "patch_b": {"ua": True, "ca": True}}
# SNR windows (per sample, dB) around PER = 1 % per (mode, channel)
WINDOWS = {("max_range", "awgn"): (-1.0, 3.0), ("max_range", "mp3"): (0.0, 4.0), ("max_range", "impaired"): (0.0, 5.0),
           ("max_rate", "awgn"): (10.0, 14.0), ("max_rate", "mp3"): (11.5, 16.0), ("max_rate", "impaired"): (13.0, 24.0)}


def one(job):
    mode, cid, cfgname, snr, seed, nsyms, npk = job
    cfg = build_config({"experiment": {"n_packets": npk, "seed": seed, "packet_gap": 12000, "lead_samples": 2000}, "payload": {"nsyms": nsyms},
                        "phy": {"mode": mode, **CONFIGS[cfgname]}, "channel": {"snr_db": snr, **CHANNELS[cid][1]}})
    try:
        r = run_experiment(cfg, outdir=None, plots=False)
        m = r.metrics
        tx = m["packets_transmitted"]
        bad = min(tx, m.get("packets_corrupted", 0) + m.get("packets_lost", 0))
        pk = r.rx_debug.get("packets", [])
        p2 = sum(1 for p in pk if (p.get("enh") or {}).get("pass2"))
        return {"tx": tx, "bad": bad, "lost": m.get("packets_lost", 0), "ber": m.get("ber_incl_lost", m.get("ber", 0.5)), "fer": m.get("fer"),
                "evm": m.get("evm_rms_pct"), "iters": m.get("ldpc_iterations_mean"), "p2": p2, "rx": len(pk)}
    except Exception as e:  # noqa: BLE001
        return {"tx": npk, "bad": npk, "lost": npk, "ber": 0.5, "fer": None, "evm": None, "iters": None, "p2": 0, "rx": 0, "err": str(e)[:80]}


def pmap(pool, fn, jobs, label, chunksize=2, every=30.0):
    """pool.imap with a progress line (done / total, percent, elapsed, estimated time left) every `every` seconds."""
    t0 = last = time.time()
    res = []
    for k, r in enumerate(pool.imap(fn, jobs, chunksize=chunksize), 1):
        res.append(r)
        now = time.time()
        if now - last >= every or k == len(jobs):
            el = now - t0
            left = el / k * (len(jobs) - k)
            print(f"{time.strftime('%H:%M:%S')} {label}: {k} / {len(jobs)} ({100 * k / len(jobs):.0f} %), elapsed {el / 60:.1f} min, left ~{left / 60:.1f} min", flush=True)
            last = now
    return res


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - h) / d), min(1.0, (c + h) / d))


def mean(v):
    v = [x for x in v if x is not None]
    return float(np.mean(v)) if v else None


def refine(a):
    """Adds a.extra runs (x 10 packets) to the points of results/rxenh/<tag>.json that bracket PER = 1 %."""
    f = Path(a.out) / f"{a.tag}.json"
    out = json.loads(f.read_text())
    jobs = []
    for mode, chans in out["curves"].items():
        for cid, cfgs in chans.items():
            xs = set()
            for pts in cfgs.values():
                for i, p in enumerate(pts):
                    if 0.002 < p["per"] < 0.15:
                        xs.add(p["x"])
                        if i + 1 < len(pts):
                            xs.add(pts[i + 1]["x"])
            want = {(c, x) for c in cfgs for x in sorted(xs)[:a.maxpts]}
            for c, pts in cfgs.items():                      # the two points that bracket PER = 1 % of every configuration
                i = max([k for k, p in enumerate(pts) if p["per"] > 0.01], default=-1)
                want |= {(c, pts[k]["x"]) for k in (i, i + 1) if 0 <= k < len(pts)}
            for cfgname, x in sorted(want):
                if next(q for q in cfgs[cfgname] if q["x"] == x).get("refined"):
                    continue
                if True:
                    for r in range(a.extra):
                        jobs.append((mode, cid, cfgname, float(x), 500000 + 17 * r + int(round(x * 10)) * 131, out["nsyms"], 10))
    print(len(jobs), "refinement runs", flush=True)
    t0 = time.time()
    with Pool(a.procs or None) as pool:
        res = pmap(pool, one, jobs, "refine")
    by = {}
    for j, r in zip(jobs, res):
        by.setdefault(j[:4], []).append(r)
    for (mode, cid, cfgname, snr), rs in by.items():
        p = next(q for q in out["curves"][mode][cid][cfgname] if abs(q["x"] - snr) < 1e-6)
        n0, n1 = p["packets"], sum(r["tx"] for r in rs)
        bad = p["errors"] + sum(r["bad"] for r in rs)
        for key, src in (("ber", "ber"), ("fer", "fer"), ("evm", "evm"), ("iters", "iters")):
            v = mean([r[src] for r in rs])
            if v is not None and p.get(key) is not None:
                p[key] = (p[key] * n0 + v * n1) / (n0 + n1)
        p["lost"] = (p["lost"] * n0 + sum(r["lost"] for r in rs)) / (n0 + n1)
        p["pass2_share"] = (p["pass2_share"] * n0 + sum(r["p2"] for r in rs)) / (n0 + n1)
        p["packets"], p["errors"], p["per"], p["ci"], p["refined"] = n0 + n1, bad, bad / (n0 + n1), list(wilson(bad, n0 + n1)), True
    f.write_text(json.dumps(out, indent=1))
    print("refined", round(time.time() - t0), "s ->", f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--procs", type=int, default=0)
    ap.add_argument("--nsyms", type=int, default=4)
    ap.add_argument("--out", default="results/rxenh")
    ap.add_argument("--tag", default="study")
    ap.add_argument("--refine", action="store_true")
    ap.add_argument("--extra", type=int, default=120)
    ap.add_argument("--maxpts", type=int, default=4)
    a = ap.parse_args()
    if a.refine:
        refine(a)
        return
    runs, npk, step = (4, 5, 1.0) if a.quick else (40, 10, 0.5)
    jobs = []
    for (mode, cid), (lo, hi) in WINDOWS.items():
        for snr in np.arange(lo, hi + 1e-9, step):
            for cfgname in CONFIGS:
                for r in range(runs):
                    jobs.append((mode, cid, cfgname, float(snr), 9000 + 17 * r + int(round(snr * 10)) * 131, a.nsyms, npk))
    print(len(jobs), "runs", flush=True)
    t0 = time.time()
    with Pool(a.procs or None) as pool:
        res = pmap(pool, one, jobs, "study")
    by = {}
    for j, r in zip(jobs, res):
        by.setdefault(j[:4], []).append(r)
    out = {"nsyms": a.nsyms, "packets_per_point": runs * npk, "channels": {k: v[0] for k, v in CHANNELS.items()}, "curves": {}}
    for (mode, cid, cfgname, snr), rs in sorted(by.items()):
        tx = sum(r["tx"] for r in rs); bad = sum(r["bad"] for r in rs)
        lo, hi = wilson(bad, tx)
        out["curves"].setdefault(mode, {}).setdefault(cid, {}).setdefault(cfgname, []).append(
            {"x": snr, "packets": tx, "errors": bad, "per": bad / tx, "ci": [lo, hi], "lost": sum(r["lost"] for r in rs) / tx, "ber": mean([r["ber"] for r in rs]),
             "fer": mean([r["fer"] for r in rs]), "evm": mean([r["evm"] for r in rs]), "iters": mean([r["iters"] for r in rs]),
             "pass2_share": sum(r["p2"] for r in rs) / max(1, sum(r["rx"] for r in rs))})
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{a.tag}.json").write_text(json.dumps(out, indent=1))
    print("done", round(time.time() - t0), "s ->", d / f"{a.tag}.json")


if __name__ == "__main__":
    main()
