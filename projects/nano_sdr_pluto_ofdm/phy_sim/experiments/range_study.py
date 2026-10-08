"""Range / robustness study with the bit-exact Python model of the RTL receiver (rx mode `fixed`).

Runs a set of one-factor sweeps through phy_sim and stores one JSON (`results/study/study.json`) that the report is built from.
usage: python experiments/range_study.py [--quick] [--out DIR]
Every point = several independent runs (different seeds), each with `n_packets` packets of `nsyms` OFDM data symbols.
Effective PER counts lost (not detected) packets as errors.
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
FAD3 = [0, 10, 25], [0, -6, -12]


def one_run(job):
    cfg_user, seed = job
    cfg_user = json.loads(json.dumps(cfg_user))
    cfg_user.setdefault("experiment", {})["seed"] = seed
    try:
        r = run_experiment(build_config(cfg_user), outdir=None, plots=False)
        m = r.metrics
        tx = m["packets_transmitted"]
        bad = m.get("packets_corrupted", 0) + m.get("packets_lost", 0)
        return {"tx": tx, "bad": min(bad, tx), "lost": m.get("packets_lost", 0), "ber": m["ber_incl_lost"] if "ber_incl_lost" in m else m["ber"],
                "evm": m.get("evm_rms_pct"), "mer": m.get("mer_db"), "cfo_err": m.get("cfo_error_abs_max_hz"),
                "tim_err": m.get("timing_error_abs_max"), "ok": True}
    except Exception as e:  # a failed detection counts as total loss
        n = int(cfg_user.get("experiment", {}).get("n_packets", 1))
        return {"tx": n, "bad": n, "lost": n, "ber": 0.5, "evm": None, "mer": None, "cfo_err": None, "tim_err": None, "ok": False, "err": str(e)[:80]}


def base(nsyms=2, n_packets=10, snr=28.0, **ch):
    return {"experiment": {"n_packets": n_packets, "packet_gap": 12000, "lead_samples": 2000},
            "payload": {"nsyms": nsyms}, "channel": {"snr_db": snr, **ch}}


def agg(rs):
    tx = sum(r["tx"] for r in rs)
    bad = sum(r["bad"] for r in rs)
    ev = [r["evm"] for r in rs if r["evm"] is not None]
    mr = [r["mer"] for r in rs if r["mer"] is not None]
    ce = [r["cfo_err"] for r in rs if r["cfo_err"] is not None]
    return {"packets": tx, "per": bad / tx, "lost": sum(r["lost"] for r in rs) / tx, "ber": float(np.mean([r["ber"] for r in rs])),
            "evm": float(np.mean(ev)) if ev else None, "mer": float(np.mean(mr)) if mr else None,
            "cfo_err": float(np.max(ce)) if ce else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default="results/study")
    a = ap.parse_args()
    runs = 2 if a.quick else 5            # independent runs per point
    npk = 10
    snr_fine = list(range(6, 31, 1)) if not a.quick else list(range(8, 31, 4))
    snr_ch = list(range(10, 33, 2)) if not a.quick else [12, 20, 28]
    exps = []   # (experiment id, title, x-name, [(x, cfg_user)])

    exps.append(("awgn", "AWGN: PER / BER / EVM vs SNR", "SNR per sample [dB]", [(s, base(snr=s)) for s in snr_fine]))

    chans = {
        "AWGN": {},
        "2 paths (0 / 11 smp, -6 dB)": {"multipath": MP2},
        "3 paths (0/10/25, 0/-6/-12 dB)": {"multipath": [{"delay": d, "gain_db": g} for d, g in zip(*FAD3)]},
        "echo 60 smp (1.95 us), -6 dB": {"multipath": [{"delay": 0, "gain_db": 0}, {"delay": 60, "gain_db": -6}]},
        "echo 120 smp (3.9 us), -6 dB": {"multipath": [{"delay": 0, "gain_db": 0}, {"delay": 120, "gain_db": -6}]},
        "echo 200 smp (6.5 us, beyond CP), -6 dB": {"multipath": [{"delay": 0, "gain_db": 0}, {"delay": 200, "gain_db": -6}]},
        "Rician K=8 dB, 20 Hz Doppler": {"fading": {"type": "rician", "doppler_hz": 20, "k_factor_db": 8, "delays": FAD3[0], "powers_db": FAD3[1]}},
        "Rayleigh, 20 Hz Doppler": {"fading": {"type": "rayleigh", "doppler_hz": 20, "delays": FAD3[0], "powers_db": FAD3[1]}},
        "Rayleigh, 200 Hz Doppler": {"fading": {"type": "rayleigh", "doppler_hz": 200, "delays": FAD3[0], "powers_db": FAD3[1]}},
    }
    for name, ch in chans.items():
        exps.append(("chan:" + name, name, "SNR per sample [dB]", [(s, base(snr=s, **ch)) for s in snr_ch]))

    cfo_x = list(range(-16000, 16001, 4000)) if a.quick else list(range(-18000, 18001, 2000))
    exps.append(("cfo", "Carrier frequency offset (SNR 28 dB)", "CFO [Hz]", [(c, base(cfo_hz=c)) for c in cfo_x]))
    exps.append(("cfo_low", "CFO at SNR 18 dB", "CFO [Hz]", [(c, base(snr=18, cfo_hz=c)) for c in (cfo_x if a.quick else range(-16000, 16001, 4000))]))
    sfo_x = [0, 5, 10, 20, 40, 80]
    exps.append(("sfo2", "Sampling clock offset, 2-symbol packets", "SFO [ppm]", [(s, base(sfo_ppm=s)) for s in sfo_x]))
    exps.append(("sfo8", "Sampling clock offset, 8-symbol packets", "SFO [ppm]", [(s, base(nsyms=8, n_packets=4, sfo_ppm=s)) for s in sfo_x]))
    exps.append(("iq", "IQ imbalance: phase error (gain 0.5 dB)", "phase error [deg]", [(p, base(iq_imbalance={"gain_db": 0.5, "phase_deg": p})) for p in (0, 2, 5, 8, 12, 18)]))
    exps.append(("pa", "Power amplifier compression (Rapp)", "input back-off [dB]", [(b, base(pa={"ibo_db": b, "smoothness": 3})) for b in (0, 1, 2, 3, 4, 6, 8, 12)]))
    exps.append(("pn", "Phase noise (Wiener, linewidth)", "linewidth [Hz]", [(l, base(phase_noise={"linewidth_hz": l})) for l in (0, 100, 1000, 3000, 10000, 30000)]))
    exps.append(("adc", "ADC level (rms in LSB, 12 bit, SNR 28 dB)", "ADC rms [LSB]", [(r, base(adc={"bits": 12, "rms": r, "clip": True})) for r in (15, 30, 60, 120, 240, 480, 700, 1000, 1400)]))
    exps.append(("dc", "ADC DC offset", "DC offset I [LSB]", [(d, base(adc={"dc_offset_i": d, "dc_offset_q": -d / 2})) for d in (0, 50, 100, 200, 400, 800)]))
    exps.append(("tone", "Narrow-band interference (tone at +1 MHz)", "SIR [dB]", [(s, base(interference={"type": "tone", "sir_db": s, "freq_hz": 1e6})) for s in (30, 20, 10, 5, 0, -5)]))
    exps.append(("len", "Packet length under fading (Rayleigh 100 Hz, SNR 24)", "OFDM symbols per packet", [(n, base(nsyms=n, n_packets=4, snr=24, fading={"type": "rayleigh", "doppler_hz": 100, "delays": FAD3[0], "powers_db": FAD3[1]})) for n in (1, 2, 4, 8)]))

    jobs, index = [], []
    for ei, (eid, title, xn, pts) in enumerate(exps):
        for pi, (x, cfg) in enumerate(pts):
            for r in range(runs):
                jobs.append((cfg, 100 + 31 * r + 7 * pi + 1000 * ei))
                index.append((ei, pi))
    print(f"{len(exps)} experiments, {len(jobs)} runs", flush=True)
    t0 = time.time()
    with Pool() as pool:
        res = []
        for i, r in enumerate(pool.imap(one_run, jobs, chunksize=2)):
            res.append(r)
            if i % 50 == 0:
                print(f"  {i}/{len(jobs)}  {time.time() - t0:.0f}s", flush=True)
    out = []
    for ei, (eid, title, xn, pts) in enumerate(exps):
        rows = []
        for pi, (x, cfg) in enumerate(pts):
            rs = [res[j] for j, ix in enumerate(index) if ix == (ei, pi)]
            rows.append({"x": x, **agg(rs)})
        out.append({"id": eid, "title": title, "xname": xn, "rows": rows})
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    (d / "study.json").write_text(json.dumps({"runs_per_point": runs, "packets_per_run": npk, "experiments": out}, indent=1))
    print("done", time.time() - t0, "s ->", d / "study.json")


if __name__ == "__main__":
    main()
