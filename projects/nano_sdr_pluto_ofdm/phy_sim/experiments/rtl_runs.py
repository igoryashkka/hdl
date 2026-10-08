"""RTL-in-the-loop runs for the report: TX (RTL) -> channel -> RX (RTL) for the new PHY (and the current PHY as a baseline) through
phy_sim + Vivado xsim, each compared with the bit-exact Python model (rx.compare_with = python:fixed).
usage: python experiments/rtl_runs.py [--quick]  -> results/compare/rtl_runs.json
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402

MP2 = [{"delay": 0, "gain_db": 0}, {"delay": 11, "gain_db": -6, "phase_deg": 45}]

CASES = [
    # name, phy mode, nsyms, packets, channel
    ("current_awgn30", "current", 2, 2, {"snr_db": 30}),
    ("new_awgn30", "new", 2, 2, {"snr_db": 30}),
    ("new_awgn18", "new", 2, 2, {"snr_db": 18}),
    ("new_awgn16", "new", 2, 2, {"snr_db": 16}),
    ("new_mp2_cfo", "new", 2, 2, {"snr_db": 20, "cfo_hz": 5000, "multipath": MP2}),
    ("new_sfo20_n4", "new", 4, 2, {"snr_db": 26, "sfo_ppm": 20, "cfo_hz": 3000}),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default="results/compare")
    a = ap.parse_args()
    cases = CASES[:2] if a.quick else CASES
    out = []
    for name, mode, nsyms, npk, ch in cases:
        t0 = time.time()
        cfg = build_config({"experiment": {"name": name, "n_packets": npk, "seed": 21, "packet_gap": 30000, "lead_samples": 1500},
                            "payload": {"nsyms": nsyms}, "phy": {"mode": mode},
                            "tx": {"backend": "rtl"}, "rx": {"backend": "rtl", "compare_with": ["python:fixed"]}, "channel": ch})
        try:
            r = run_experiment(cfg, outdir=None, plots=False)
            m = r.metrics
            cmp_ = m.get("comparison", {}).get("python:fixed", {})
            checks = cmp_.get("checks", [])
            keep = ("ber", "per", "fer", "evm_rms_pct", "mer_db", "papr_db", "cfo_error_abs_max_hz", "timing_error_abs_max", "channel_est_mse_db",
                    "ldpc_iterations_mean", "ldpc_iterations_max", "ldpc_decoding_failures", "channel_snr_db_mean", "snr_min_db_mean",
                    "bad_subcarriers_mean", "fine_timing_error_abs_max", "sfo_estimation_error_ppm", "cfo_residual_estimate_hz_absmax",
                    "packets_transmitted", "packets_received", "rtl_performance")
            res = {"name": name, "mode": mode, "nsyms": nsyms, "channel": ch, "runtime_s": round(time.time() - t0, 1),
                   "metrics": {k: m[k] for k in keep if k in m},
                   "model_checks": {"total": len(checks), "ok": sum(1 for c in checks if c.get("ok")), "failed": [c.get("name") for c in checks if not c.get("ok")]},
                   "rx_perf": r.rx_debug.get("perf"), "rx_status": r.rx_debug.get("status")}
        except Exception as e:
            res = {"name": name, "mode": mode, "error": str(e)[:300]}
        out.append(res)
        print(name, json.dumps(res.get("metrics", res), default=str)[:300], flush=True)
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    (d / "rtl_runs.json").write_text(json.dumps(out, indent=1, default=str))
    print("-> ", d / "rtl_runs.json")


if __name__ == "__main__":
    main()
