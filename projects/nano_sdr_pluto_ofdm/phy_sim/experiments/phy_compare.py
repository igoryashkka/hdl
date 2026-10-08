"""Current PHY (16-QAM, ZF, hard decision) vs new PHY (LDPC R=5/6 + soft LLR + MMSE/ZF + SFO tracking + fine timing).

Both are run through phy_sim with the bit-exact Python models of the RTL receivers (rx mode `fixed`); packets carry 2 OFDM data symbols
(1100 payload bytes for the current PHY, 900 bytes for the coded PHY) unless stated otherwise. Output: results/compare/compare.json.
usage: python experiments/phy_compare.py [--quick] [--procs N]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402

MP2 = [{"delay": 0, "gain_db": 0}, {"delay": 11, "gain_db": -6, "phase_deg": 45}]
MP3 = [{"delay": 0, "gain_db": 0}, {"delay": 10, "gain_db": -6}, {"delay": 25, "gain_db": -12}]
ECHO120 = [{"delay": 0, "gain_db": 0}, {"delay": 120, "gain_db": -6}]
FAD3 = {"delays": [0, 10, 25], "powers_db": [0, -6, -12]}


def one_run(job):
    cfg_user, seed = job
    c = json.loads(json.dumps(cfg_user))
    c.setdefault("experiment", {})["seed"] = seed
    try:
        r = run_experiment(build_config(c), outdir=None, plots=False)
        m = r.metrics
        tx = m["packets_transmitted"]
        bad = min(tx, m.get("packets_corrupted", 0) + m.get("packets_lost", 0))
        return {"tx": tx, "bad": bad, "lost": m.get("packets_lost", 0), "ber": m.get("ber_incl_lost", m.get("ber", 0.5)),
                "evm": m.get("evm_rms_pct"), "cfo_err": m.get("cfo_error_abs_max_hz"), "tim_err": m.get("timing_error_abs_max"),
                "ftim": m.get("fine_timing_error_abs_max"), "sfo_err": m.get("sfo_estimation_error_ppm"),
                "fer": m.get("fer"), "iters": m.get("ldpc_iterations_mean"), "fail_cw": m.get("ldpc_decoding_failures", 0),
                "chan_snr": m.get("channel_snr_db_mean"), "snr_min": m.get("snr_min_db_mean"), "bad_sc": m.get("bad_subcarriers_mean"),
                "cfo_res": m.get("cfo_residual_estimate_hz_absmax"), "bits": m.get("bits_transmitted", 0)}
    except Exception as e:  # undetected / crashed -> total loss
        n = int(c.get("experiment", {}).get("n_packets", 1))
        return {"tx": n, "bad": n, "lost": n, "ber": 0.5, "evm": None, "cfo_err": None, "tim_err": None, "ftim": None, "sfo_err": None,
                "fer": None, "iters": None, "fail_cw": 0, "chan_snr": None, "snr_min": None, "bad_sc": None, "cfo_res": None, "bits": 0,
                "err": str(e)[:60]}


def mean(rs, k):
    v = [r[k] for r in rs if r.get(k) is not None]
    return float(np.mean(v)) if v else None


def agg(rs):
    tx = sum(r["tx"] for r in rs)
    bad = sum(r["bad"] for r in rs)
    ca = [r["cfo_err"] for r in rs if r["cfo_err"] is not None]
    return {"packets": tx, "per": bad / tx, "lost": sum(r["lost"] for r in rs) / tx, "ber": mean(rs, "ber"), "evm": mean(rs, "evm"),
            "fer": mean(rs, "fer"), "iters": mean(rs, "iters"), "chan_snr": mean(rs, "chan_snr"), "snr_min": mean(rs, "snr_min"),
            "bad_sc": mean(rs, "bad_sc"), "cfo_err": float(np.max(ca)) if ca else None, "ftim": mean(rs, "ftim"),
            "sfo_err": mean(rs, "sfo_err"), "cfo_res": mean(rs, "cfo_res")}


def base(phy, snr=None, nsyms=2, n_packets=10, **ch):
    d = {"experiment": {"n_packets": n_packets, "packet_gap": 12000, "lead_samples": 2000}, "payload": {"nsyms": nsyms},
         "phy": {"mode": "new" if phy.startswith("new") else "current", "eq": "zf" if phy == "new_zf" else "mmse"},
         "channel": {"snr_db": snr, **ch}}
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--procs", type=int, default=0)
    ap.add_argument("--out", default="results/compare")
    a = ap.parse_args()
    runs = 3 if a.quick else 10
    exps = []                                   # (id, title, xname, series: {name: [(x, cfg)]})

    def snr_series(name, phys, snrs, **ch):
        return {p: [(s, base(p, s, **ch)) for s in snrs] for p in phys}

    two = ["current", "new"]
    snr_a = list(range(6, 36, 1)) if not a.quick else list(range(8, 34, 4))
    snr_c = list(range(6, 36, 2)) if not a.quick else list(range(10, 34, 6))
    exps.append(("awgn", "AWGN", "SNR per sample [dB]", snr_series("awgn", two, snr_a)))
    for eid, title, ch, phys in (
            ("mp2", "2 paths (0.36 us, -6 dB)", {"multipath": MP2}, ["current", "new", "new_zf"]),
            ("mp3", "3 paths (0 / 0.33 / 0.81 us)", {"multipath": MP3}, ["current", "new", "new_zf"]),
            ("echo120", "echo 3.9 us, -6 dB", {"multipath": ECHO120}, two),
            ("rician", "Rician K = 8 dB, 20 Hz Doppler", {"fading": {"type": "rician", "doppler_hz": 20, "k_factor_db": 8, **FAD3}}, ["current", "new", "new_zf"]),
            ("rayleigh20", "Rayleigh 20 Hz Doppler", {"fading": {"type": "rayleigh", "doppler_hz": 20, **FAD3}}, ["current", "new", "new_zf"]),
            ("rayleigh200", "Rayleigh 200 Hz Doppler", {"fading": {"type": "rayleigh", "doppler_hz": 200, **FAD3}}, two)):
        exps.append((eid, title, "SNR per sample [dB]", snr_series(eid, phys, snr_c, **ch)))

    cfo_x = list(range(-16000, 16001, 4000)) if a.quick else list(range(-16000, 16001, 2000))
    exps.append(("cfo28", "CFO at SNR 28 dB", "CFO [Hz]", {p: [(c, base(p, 28, cfo_hz=c)) for c in cfo_x] for p in two}))
    exps.append(("cfo22", "CFO at SNR 22 dB", "CFO [Hz]", {p: [(c, base(p, 22, cfo_hz=c)) for c in (cfo_x if a.quick else range(-16000, 16001, 4000))] for p in two}))
    sfo_x = [0, 5, 10, 20, 30, 40]
    exps.append(("sfo2", "SFO, 2-symbol packets, SNR 28 dB", "SFO [ppm]", {p: [(x, base(p, 28, sfo_ppm=x)) for x in sfo_x] for p in two}))
    exps.append(("sfo8", "SFO, 8-symbol packets, SNR 28 dB", "SFO [ppm]", {p: [(x, base(p, 28, nsyms=8, n_packets=4, sfo_ppm=x)) for x in sfo_x] for p in two}))
    exps.append(("iq", "IQ imbalance (phase error, 0.5 dB gain)", "phase error [deg]", {p: [(x, base(p, 28 if p == "current" else 24, iq_imbalance={"gain_db": 0.5, "phase_deg": x})) for x in (0, 2, 5, 8, 12, 18)] for p in two}))
    exps.append(("pa", "Power amplifier compression", "input back-off [dB]", {p: [(x, base(p, 28 if p == "current" else 24, pa={"ibo_db": x, "smoothness": 3})) for x in (0, 1, 2, 3, 4, 6, 8, 12)] for p in two}))
    exps.append(("pn", "Phase noise (Wiener linewidth)", "linewidth [Hz]", {p: [(x, base(p, 28 if p == "current" else 24, phase_noise={"linewidth_hz": x})) for x in (0, 30, 100, 300, 1000, 3000)] for p in two}))
    exps.append(("adc", "ADC level (rms, 12 bit)", "ADC rms [LSB]", {p: [(x, base(p, 28 if p == "current" else 24, adc={"bits": 12, "rms": x, "clip": True})) for x in (30, 60, 120, 240, 480, 700, 1000, 1400)] for p in two}))
    exps.append(("tone", "Narrow-band interference (+1 MHz tone)", "SIR [dB]", {p: [(x, base(p, 28 if p == "current" else 24, interference={"type": "tone", "sir_db": x, "freq_hz": 1e6})) for x in (30, 20, 10, 5, 0)] for p in two}))

    jobs, index = [], []
    for ei, (eid, title, xn, series) in enumerate(exps):
        for si, (name, pts) in enumerate(series.items()):
            for pi, (x, cfg) in enumerate(pts):
                n_runs = runs * (2 if eid.startswith("rayleigh") or eid == "rician" else 1)
                if eid in ("rayleigh20", "rayleigh200", "rician"):
                    cfg = json.loads(json.dumps(cfg)); cfg["experiment"]["n_packets"] = 5
                for r in range(n_runs):
                    jobs.append((cfg, 500 + 53 * r + 7 * pi + 1000 * ei + 13 * si))
                    index.append((ei, name, pi))
    print(f"{len(exps)} experiments, {len(jobs)} runs", flush=True)
    t0 = time.time()
    procs = a.procs or None
    with Pool(procs) as pool:
        res = []
        for i, r in enumerate(pool.imap(one_run, jobs, chunksize=2)):
            res.append(r)
            if i % 200 == 0:
                print(f"  {i}/{len(jobs)} {time.time() - t0:.0f}s", flush=True)
    by = {}
    for ix, r in zip(index, res):
        by.setdefault(ix, []).append(r)
    out = []
    for ei, (eid, title, xn, series) in enumerate(exps):
        sers = {}
        for name, pts in series.items():
            sers[name] = [{"x": x, **agg(by[(ei, name, pi)])} for pi, (x, cfg) in enumerate(pts)]
        out.append({"id": eid, "title": title, "xname": xn, "series": sers})
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    (d / "compare.json").write_text(json.dumps({"runs": runs, "experiments": out}, indent=1))
    print("done", round(time.time() - t0), "s ->", d / "compare.json")


if __name__ == "__main__":
    main()
