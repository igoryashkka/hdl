"""Dual-mode PHY study (ТЗ 003): Reference PHY (16-QAM + LDPC 5/6 + ZF + hard LLR) vs MAX RANGE (QPSK + LDPC 1/2) vs MAX RATE (16-QAM + LDPC 5/6),
benchmark channels, ablation chain, leave-one-out, impairment robustness. Everything runs through phy_sim with the bit-exact Python models of the RTL
receivers (python:fixed). Output: results/dualmode/study.json.

SNR is the SNR per sample in the 30.72 MHz band (same definition as the earlier reports). A point = N_RUNS runs x 10 packets; the threshold
SNR(PER<=1 %) is the lowest grid SNR from which PER stays <= 1 % on all higher grid points.
Adaptive grid: a coarse pass (3 dB steps, 30 packets) finds the knee, a fine pass (1 dB steps over knee - 4 .. knee + 1, 100 packets) measures it.

usage: python experiments/dualmode_study.py [--quick] [--procs N] [--only benchmark,ablation,loo,robust]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import zlib
from multiprocessing import Pool
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from phy_compare import one_run, agg, MP2, MP3, ECHO120, FAD3  # noqa: E402

RF_CH = {"multipath": MP3, "cfo_hz": 4000, "sfo_ppm": 15, "phase_noise": {"linewidth_hz": 50}, "iq_imbalance": {"gain_db": 0.5, "phase_deg": 3}}
CHANNELS = {
    "awgn": ("AWGN", {}),
    "mp2": ("2 paths (0.36 us, -6 dB)", {"multipath": MP2}),
    "mp3": ("3 paths (0 / 0.33 / 0.81 us)", {"multipath": MP3}),
    "echo120": ("echo 3.9 us, -6 dB", {"multipath": ECHO120}),
    "rician": ("Rician K = 8 dB, 20 Hz Doppler", {"fading": {"type": "rician", "doppler_hz": 20, "k_factor_db": 8, **FAD3}}),
    "rayleigh20": ("Rayleigh 20 Hz Doppler", {"fading": {"type": "rayleigh", "doppler_hz": 20, **FAD3}}),
    "rayleigh200": ("Rayleigh 200 Hz Doppler", {"fading": {"type": "rayleigh", "doppler_hz": 200, **FAD3}}),
    "rf": ("3 paths + CFO 4 kHz + SFO 15 ppm + phase noise 50 Hz + IQ 0.5 dB / 3 deg", RF_CH),
}
REF = {"mode": "reference"}
RATE = {"mode": "max_rate"}
RANGE = {"mode": "max_range"}
# ablation chain (ТЗ 003 section 23); every step changes one thing relative to the previous one
ABL = [
    ("0 Current PHY (16-QAM, LDPC 5/6, ZF, hard LLR)", {"mode": "reference"}),
    ("1 + QPSK", {"mode": "reference", "layout": ["qpsk", "r56"]}),
    ("2 + LDPC 1/2", {"mode": "reference", "layout": ["qpsk", "r12"]}),
    ("3 + soft LLR (global noise estimate)", {"mode": "reference", "layout": ["qpsk", "r12"], "llr": "uniform"}),
    ("4 + MMSE (per-bin gain and bias)", {"mode": "reference", "layout": ["qpsk", "r12"], "llr": "weighted", "eq": "mmse"}),
    ("5 + fine timing", {"mode": "reference", "layout": ["qpsk", "r12"], "llr": "weighted", "eq": "mmse", "fine_timing": True}),
    ("6 + CPE tracking (already in the Current PHY)", {"mode": "reference", "layout": ["qpsk", "r12"], "llr": "weighted", "eq": "mmse", "fine_timing": True}),
    ("7 + SFO tracking", {"mode": "reference", "layout": ["qpsk", "r12"], "llr": "weighted", "eq": "mmse", "fine_timing": True, "sfo": True}),
    ("8 + channel estimate smoothing (MAX RANGE)", {"mode": "max_range"}),
]
LOO = [
    ("MAX RANGE (all features)", {"mode": "max_range"}),
    ("- smoothing", {"mode": "max_range", "chest_smooth": 0}),
    ("- SFO tracking", {"mode": "max_range", "sfo": False}),
    ("- CPE tracking", {"mode": "max_range", "cpe": False}),
    ("- fine timing", {"mode": "max_range", "fine_timing": False}),
    ("- MMSE (ZF)", {"mode": "max_range", "eq": "zf", "llr": "uniform"}),
    ("- soft LLR (hard decisions)", {"mode": "max_range", "llr": "hard"}),
]
NS = 4                      # data symbols per packet in the ablation / leave-one-out experiments (long enough for SFO / CPE tracking)


def cfg_for(phy: dict, ch: dict, snr: float, nsyms: int = 2, n_packets: int = 10) -> dict:
    return {"experiment": {"n_packets": n_packets, "packet_gap": 12000, "lead_samples": 2000}, "payload": {"nsyms": nsyms}, "phy": dict(phy),
            "channel": {"snr_db": snr, **ch}}


def _job(arg):
    key, cfg, seed = arg
    return key, one_run((cfg, seed))


def run_points(pool, points, n_runs):
    """points: list of (key, cfg) -> {key: agg dict}"""
    jobs = []
    for key, cfg in points:
        for r in range(n_runs.get(key, 10) if isinstance(n_runs, dict) else n_runs):
            jobs.append((key, cfg, 700 + 37 * r + (zlib.crc32(str(key).encode()) % 997)))
    by = {}
    for key, res in pool.imap_unordered(_job, jobs, chunksize=2):
        by.setdefault(key, []).append(res)
    return {k: agg(v) for k, v in by.items()}


def study(pool, specs, quick):
    """specs: {sid: (phy, ch, nsyms, lo, hi)} -> {sid: [points]} using the adaptive coarse / fine grid."""
    n_coarse, n_fine = (1, 3) if quick else (3, 10)
    coarse = {}
    pts = []
    for sid, (phy, ch, nsyms, lo, hi) in specs.items():
        for snr in range(lo, hi + 1, 3):
            pts.append(((sid, snr), cfg_for(phy, ch, snr, nsyms)))
    res = run_points(pool, pts, n_coarse)
    for (sid, snr), a in res.items():
        coarse.setdefault(sid, {})[snr] = a
    fine_pts, fine_set = [], {}
    for sid, (phy, ch, nsyms, lo, hi) in specs.items():
        c = coarse[sid]
        knee = None
        for snr in sorted(c):                     # first coarse point from which PER stays below 5 % (or hi)
            if all(c[s2]["per"] < 0.05 for s2 in c if s2 >= snr):
                knee = snr
                break
        if knee is None:
            knee = hi
        grid = [s for s in range(knee - 4, knee + 2) if s not in c]
        fine_set[sid] = (knee, grid)
        for snr in grid:
            fine_pts.append(((sid, snr), cfg_for(phy, ch, snr, nsyms)))
    res2 = run_points(pool, fine_pts, n_fine)
    out = {}
    for sid in specs:
        allp = dict(coarse[sid])
        for (s2, snr), a in res2.items():
            if s2 == sid:
                allp[snr] = a
        out[sid] = [{"x": snr, **allp[snr]} for snr in sorted(allp)]
    return out


def threshold(pts, lim=0.01):
    b = None
    for p in reversed(pts):
        if p["per"] <= lim:
            b = p["x"]
        else:
            break
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--procs", type=int, default=0)
    ap.add_argument("--out", default="results/dualmode")
    ap.add_argument("--only", default="benchmark,ablation,loo,robust")
    a = ap.parse_args()
    only = set(a.only.split(","))
    t0 = time.time()
    out = {"quick": a.quick, "channels": {k: v[0] for k, v in CHANNELS.items()}}
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    with Pool(a.procs or None) as pool:
        if "benchmark" in only:
            specs = {}
            for cid in ("awgn", "mp2", "mp3", "echo120", "rician", "rayleigh20", "rayleigh200", "rf"):
                ch = CHANNELS[cid][1]
                specs[(cid, "reference")] = (REF, ch, 2, 9, 36)
                specs[(cid, "max_rate")] = (RATE, ch, 2, 6, 36)
                specs[(cid, "max_range")] = (RANGE, ch, 2, -6, 24)
            res = study(pool, specs, a.quick)
            out["benchmark"] = {cid: {ph: res[(cid, ph)] for ph in ("reference", "max_rate", "max_range")} for cid in CHANNELS}
            print("benchmark done", round(time.time() - t0), "s", flush=True)
        if "ablation" in only:
            specs = {}
            for cid in ("awgn", "mp3", "rf"):
                for i, (name, phy) in enumerate(ABL):
                    if i == 6:
                        continue
                    lo, hi = (9, 36) if i == 0 else (6, 33) if i == 1 else (-6, 24)
                    specs[(cid, i)] = (phy, CHANNELS[cid][1], NS, lo, hi)
            res = study(pool, specs, a.quick)
            out["ablation"] = {cid: {str(i): res[(cid, i)] for i in range(len(ABL)) if i != 6} for cid in ("awgn", "mp3", "rf")}
            out["ablation_steps"] = [n for n, _ in ABL]
            print("ablation done", round(time.time() - t0), "s", flush=True)
        if "loo" in only:
            specs = {}
            for cid in ("awgn", "rf"):
                for i, (name, phy) in enumerate(LOO):
                    specs[(cid, i)] = (phy, CHANNELS[cid][1], NS, -6, 24)
            res = study(pool, specs, a.quick)
            out["loo"] = {cid: {str(i): res[(cid, i)] for i in range(len(LOO))} for cid in ("awgn", "rf")}
            out["loo_steps"] = [n for n, _ in LOO]
            print("leave-one-out done", round(time.time() - t0), "s", flush=True)
        if "robust" in only:
            # robustness at a fixed SNR margin above each mode's AWGN threshold
            thr = {ph: threshold(out["benchmark"]["awgn"][ph]) if "benchmark" in out else None for ph in ("reference", "max_rate", "max_range")}
            margin = 4
            rob = {}
            tests = {
                "cfo": [("cfo_hz", v) for v in range(-16000, 16001, 4000)],
                "sfo": [("sfo_ppm", v) for v in (0, 5, 10, 20, 30, 40)],
                "pn": [("phase_noise", {"linewidth_hz": v}) for v in (0, 30, 100, 300, 1000)],
                "iq": [("iq_imbalance", {"gain_db": 0.5, "phase_deg": v}) for v in (0, 2, 5, 8, 12)],
                "tone": [("interference", {"type": "tone", "sir_db": v, "freq_hz": 1e6}) for v in (30, 20, 10, 5, 0)],
            }
            pts, index = [], {}
            for tid, lst in tests.items():
                for ph, phy in (("reference", REF), ("max_rate", RATE), ("max_range", RANGE)):
                    snr = (thr[ph] if thr[ph] is not None else 20) + margin
                    for j, (k, v) in enumerate(lst):
                        key = (tid, ph, j)
                        pts.append((key, cfg_for(phy, {k: v}, snr, NS if tid == "sfo" else 2)))
                        index[key] = (tid, ph, v if not isinstance(v, dict) else list(v.values())[-1])
            res = run_points(pool, pts, 3 if a.quick else 10)
            for key, a_ in res.items():
                tid, ph, x = index[key]
                rob.setdefault(tid, {}).setdefault(ph, []).append({"x": x, "j": key[2], **a_})
            for tid in rob:
                for ph in rob[tid]:
                    rob[tid][ph].sort(key=lambda p: p["j"])
            out["robust"] = {"margin_db": margin, "thr": thr, "tests": rob}
            print("robustness done", round(time.time() - t0), "s", flush=True)
    (d / "study.json").write_text(json.dumps(out, indent=1, default=str))
    print("done", round(time.time() - t0), "s ->", d / "study.json")


if __name__ == "__main__":
    main()
