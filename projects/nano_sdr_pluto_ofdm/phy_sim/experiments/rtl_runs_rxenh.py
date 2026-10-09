"""ТЗ 004: RTL simulation of Baseline / Patch A / Patch B on the same samples as the Python reference -> results/rxenh/rtl.json

For every scenario (mode, channel, SNR inside the waterfall) and configuration the same packets (payloads, channel realisation, noise) go through
  * the Python fixed-point receiver (python:fixed), and
  * the RTL receiver phy_rx_top in xsim (tb_rtl_rx_file, parameters UA / CA).
Two comparisons per packet:
  1. replay (bit-exact check of the patches): the tracker output and the per-bin demapper parameters logged by the RTL simulation are fed to
     the fixed-point models of the back-end (rxenh_fixed_ref.receive_decode: demapper, LDPC, code-aided second pass); bytes, failed codewords,
     iteration sum / maximum, "second pass ran" and "codewords repaired" must be identical to the RTL packet record;
  2. end to end: packets decoded without error by the Python receiver and by the RTL receiver (the front ends are not bit-identical: the NCO
     phase origin and the detector timing of the stream model differ by design, so single packets inside the waterfall may differ).
usage: python experiments/rtl_runs_rxenh.py [--only name] [--packets N] [--nsyms N]
       python experiments/rtl_runs_rxenh.py --check      regression entry (sim/run_regression.sh): Patch B on two short scenarios, exit code 0 only
                                                         if every RTL packet equals the model and the second pass ran and repaired a codeword"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim import refs  # noqa: E402
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402

X = refs.rxenh_fixed_ref
MP3 = [{"delay": 0, "gain_db": 0}, {"delay": 10, "gain_db": -6}, {"delay": 25, "gain_db": -12}]
IMP = {"multipath": MP3, "cfo_hz": 4000, "sfo_ppm": 15, "timing_offset": 3, "fractional_delay": 0.4, "phase_noise": {"linewidth_hz": 50}}
CONFIGS = {"baseline": {}, "patch_a": {"ua": True}, "patch_b": {"ua": True, "ca": True}}
# (name, mode, channel, SNR per sample [dB]): operating points inside the waterfall, where codewords fail and the second pass runs
SCENARIOS = [
    ("range_awgn", "max_range", {}, 0.5),
    ("range_mp3", "max_range", {"multipath": MP3}, 1.5),
    ("range_impaired", "max_range", IMP, 2.0),
    ("rate_awgn", "max_rate", {}, 11.0),
    ("rate_mp3", "max_rate", {"multipath": MP3}, 12.5),
    ("rate_impaired", "max_rate", IMP, 14.5),
]


def run(mode, chan, snr, cfgname, backend, npk, nsyms, seed):
    cfg = build_config({"experiment": {"n_packets": npk, "seed": seed, "packet_gap": 30000, "lead_samples": 2000}, "payload": {"nsyms": nsyms},
                        "phy": {"mode": mode, **CONFIGS[cfgname]}, "rx": {"backend": backend}, "channel": {"snr_db": snr, **chan}})
    r = run_experiment(cfg, outdir=None, plots=False)
    return r, r.rx_debug.get("packets", [])


def replay(pk, nsyms, ua, ca):
    """Back-end of one RTL packet in the fixed-point models: (bytes, failed, iteration sum, iteration max, second pass ran, repaired)."""
    mode = int(pk["mode_used"])
    prm = np.array(pk["prm"], dtype=np.int64)
    T, gm, ge = (prm >> 13) & 0xFFFF, (prm >> 7) & 0x3F, prm & 0x7F
    ge = np.where(ge >= 64, ge - 128, ge)
    eq = [(np.rint(s.real).astype(np.int64), np.rint(s.imag).astype(np.int64)) for s in pk["eq"]]
    qp = refs.phy2_ref.layout(mode)["mod"] == "qpsk"
    llr = [X.demap(xr, xi, T, gm, ge, qp, False) for xr, xi in eq]
    data, its, done, info = X.receive_decode(llr, {"eq": eq, "T": T, "gm": gm, "ge": ge}, nsyms, mode, len(pk["bytes"]), 10, ua, ca)
    return data, int((~done).sum()), int(its.sum()), int(its.max()), bool(info.get("pass2")), int(info.get("fixed_cw", 0))


def n_ok(r):
    m = r.metrics
    return int(m["packets_transmitted"] - min(m["packets_transmitted"], m.get("packets_corrupted", 0) + m.get("packets_lost", 0)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--packets", type=int, default=8)
    ap.add_argument("--nsyms", type=int, default=4)
    ap.add_argument("--seed", type=int, default=4242)
    ap.add_argument("--out", default="results/rxenh/rtl.json")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        a.packets, a.nsyms = 4, 2
    out = {"packets": a.packets, "nsyms": a.nsyms, "runs": []}
    # --check: two points low enough in the waterfall that the first pass leaves failed codewords in a 4-packet run
    scen = [("range_mp3", "max_range", {"multipath": MP3}, 1.5), ("rate_awgn", "max_rate", {}, 10.6)] if a.check else SCENARIOS
    for name, mode, chan, snr in scen:
        if a.only and a.only != name:
            continue
        for cfgname, opt in CONFIGS.items():
            if a.check and cfgname != "patch_b":
                continue
            t0 = time.time()
            print(f"{time.strftime('%H:%M:%S')} start {name} / {cfgname} (python, then RTL in xsim)", flush=True)
            rp, pp = run(mode, chan, snr, cfgname, "python", a.packets, a.nsyms, a.seed)
            rr, pr = run(mode, chan, snr, cfgname, "rtl", a.packets, a.nsyms, a.seed)
            exact, diffs, p2, fixed, fails = 0, [], 0, 0, 0
            for k, pk in enumerate(pr):
                if "prm" not in pk or "eq" not in pk:
                    diffs.append({"packet": k, "what": "no debug data"})
                    continue
                got = (pk["bytes"], int(pk["ldpc_failures"]), int(round(sum(pk["ldpc_iterations"]))), int(pk["ldpc_iter_max"]),
                       bool(pk["enh"]["pass2"]), int(pk["enh"]["fixed_cw"]))
                exp = replay(pk, a.nsyms, bool(opt.get("ua")), bool(opt.get("ca")))
                if got == exp:
                    exact += 1
                else:
                    diffs.append({"packet": k, "rtl": [len(got[0])] + list(got[1:]), "model": [len(exp[0])] + list(exp[1:]),
                                  "byte_diffs": sum(x != y for x, y in zip(got[0], exp[0]))})
                p2 += int(got[4]); fixed += got[5]; fails += got[1]
            perf = rr.metrics.get("rtl_performance", {})
            lat = rr.rx_debug.get("perf", {}).get("rx_latency_clks_all", [])
            rec = {"scenario": name, "mode": mode, "snr_db": snr, "config": cfgname, "packets_tx": a.packets, "packets_rtl": len(pr), "packets_python": len(pp),
                   "replay_exact": exact, "replay_diffs": diffs, "rtl_pass2_packets": p2, "rtl_fixed_cw": fixed, "rtl_failed_cw": fails,
                   "ok_python": n_ok(rp), "ok_rtl": n_ok(rr), "rx_latency_clks": lat, "pass2_clks": rr.rx_debug.get("pass2_clks", []),
                   "clk_hz": 61.44e6, "seconds": round(time.time() - t0)}
            out["runs"].append(rec)
            print(json.dumps(rec), flush=True)
    if a.check:
        ok = all(r["replay_exact"] == r["packets_rtl"] == a.packets for r in out["runs"]) and all(r["rtl_pass2_packets"] > 0 for r in out["runs"]) \
            and sum(r["rtl_fixed_cw"] for r in out["runs"]) > 0
        print("TEST PASSED rxenh_rtl_check" if ok else "TEST FAILED rxenh_rtl_check")
        sys.exit(0 if ok else 1)
    if not a.only:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(json.dumps(out, indent=1))
        print("->", a.out)


if __name__ == "__main__":
    main()
