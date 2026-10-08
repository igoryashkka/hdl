"""RTL facts for the dual-mode report -> results/dualmode/rtl.json
  * testbench regression result (sim/run_regression.sh log),
  * LDPC decode time per iteration of both codes (tb_phy_ldpc_dec, LDPCSTAT lines),
  * RTL packet latencies of both modes (phy_sim, TX RTL -> channel -> RX RTL),
  * out-of-context synthesis estimates (synth/synth_est.tcl): utilisation + timing of phy_rx_top / phy_tx_top.
usage: python experiments/rtl_runs_dm.py [--regression path/to/regression.log] [--skip-sim]"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]                                    # nano_sdr_pluto_ofdm
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
from collect_resources import parse_hier, parse_util  # noqa: E402

BASH = r"C:\Program Files\Git\bin\bash.exe"


def parse_regression(path: Path) -> list[dict]:
    out = []
    for line in path.read_text(errors="ignore").splitlines():
        m = re.match(r"^(PASS|FAIL) (\S+)\s*(.*)$", line)
        if m:
            out.append({"name": m.group(2), "generic": m.group(3).strip(), "pass": m.group(1) == "PASS"})
    return out


def decode_cycles(skip: bool) -> dict:
    """LDPCSTAT lines of tb_phy_ldpc_dec (MODE=0 / 1) saved in results/dualmode/ldpcstat.txt (cycles between status pulses; the codewords that run
    the full 10 iterations give the decode time per iteration)."""
    f = Path("results/dualmode/ldpcstat.txt")
    res = {}
    rows = [dict(re.findall(r"(\w+)=(\d+)", ln)) for ln in f.read_text().splitlines()] if f.exists() else []
    for mode, key, wps in ((0, "range", 1), (1, "rate", 2)):
        rr = [{k: int(v) for k, v in r.items()} for r in rows if int(r["mode"]) == mode]
        full = [r for r in rr if r["iter"] == 10]
        cpi = sum(r["dt"] for r in full) / sum(r["iter"] for r in full) if full else 0.0
        res[key] = {"cycles_per_iter": cpi, "words_per_sym": wps, "samples": rr}
    return res


def packet_latency(skip: bool) -> dict:
    if skip:
        return {"rx_latency_us": {"range": 0.0, "rate": 0.0}, "tx_latency_us": {"range": 0.0, "rate": 0.0}}
    from phy_sim.core.config import build_config
    from phy_sim.core.experiment import run_experiment
    out = {"rx_latency_us": {}, "tx_latency_us": {}, "payload_rate_mbps": {}}
    for mode, key in (("max_range", "range"), ("max_rate", "rate")):
        cfg = build_config({"experiment": {"n_packets": 2, "seed": 5, "packet_gap": 30000, "lead_samples": 1500}, "payload": {"nsyms": 2}, "phy": {"mode": mode},
                            "tx": {"backend": "rtl"}, "rx": {"backend": "rtl"}, "channel": {"snr_db": 30}})
        m = run_experiment(cfg, outdir=None, plots=False).metrics
        p = m.get("rtl_performance", {})
        out["rx_latency_us"][key] = float(p.get("rx_packet_latency_us") or 0)
        out["tx_latency_us"][key] = float(p.get("tx_packet_latency_us") or 0)
        out["payload_rate_mbps"][key] = {k: p.get(k) for k in ("phy_payload_rate_mbps_asymptotic", "phy_payload_rate_mbps_8_symbols", "phy_payload_rate_mbps_this_packet_size")}
    return out


def synth_reports() -> dict:
    dirs = {"rx": ROOT / "synth" / "out_final3", "tx": ROOT / "synth" / "out_final"}
    res = {"part": "xc7z020clg400-1"}
    for v, top in (("rx", "phy_rx_top"), ("tx", "phy_tx_top")):
        d = dirs[v]
        u = parse_util(d / f"{top}_util.rpt") if (d / f"{top}_util.rpt").exists() else {}
        rec = {"util": {"lut": int(u.get("lut", 0)), "ff": int(u.get("ff", 0)), "bram": u.get("bram", 0), "dsp": int(u.get("dsp", 0)), "lutram": int(u.get("lutram", 0))}}
        t = (d / f"{top}_timing.rpt")
        wns = None
        if t.exists():
            m = re.search(r"WNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)", t.read_text(errors="ignore"), re.S)
            wns = float(m.group(1)) if m else None
        rec["wns"] = wns
        h = d / f"{top}_util_hier.rpt"
        if h.exists():
            rows = parse_hier(h)
            top_level = [r for r in rows if r["depth"] <= 4 and r["lut"] > 300 and r["inst"] != top]
            top_level.sort(key=lambda r: -r["lut"])
            rec["hier"] = [{k: r[k] for k in ("inst", "module", "lut", "ff", "bram36", "dsp")} for r in top_level[:14]]
            rec["hier"] = [{**r, "bram": r.pop("bram36")} for r in rec["hier"]]
        res[v] = rec
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--regression", default=r"C:\Users\user\regression.log")
    ap.add_argument("--skip-sim", action="store_true")
    ap.add_argument("--out", default="results/dualmode")
    a = ap.parse_args()
    out = {"tb": parse_regression(Path(a.regression)), "decode": decode_cycles(a.skip_sim), "perf": packet_latency(a.skip_sim), "res": synth_reports()}
    Path(a.out).mkdir(parents=True, exist_ok=True)
    Path(a.out, "rtl.json").write_text(json.dumps(out, indent=1))
    print("tb", len(out["tb"]), "pass", sum(t["pass"] for t in out["tb"]), "| decode", {k: round(v["cycles_per_iter"]) for k, v in out["decode"].items()}, "| res", out["res"].get("rx", {}).get("util"))


if __name__ == "__main__":
    main()
