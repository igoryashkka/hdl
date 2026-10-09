"""Builds the ТЗ 004 report (single HTML page) from results/rxenh: study.json (PER curves of Baseline / Patch A / Patch B), diag.json and det.json
(diagnostics for the next algorithm), rtl.json (RTL against the models), regression logs, Vivado reports of the three implementations
(impl_<name>/) and out-of-context synthesis estimates (synth_<name>/), RX optimisation before / after (synth/out_final3, synth/out_opt2).
usage: python experiments/build_rxenh_report.py [resultsdir] [out.html]"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from collect_resources import parse_hier, parse_util  # noqa: E402

RES = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "results" / "rxenh"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else RES / "rxenh_report.html"
BLOCKS = ("u_phy", "u_sync", "u_cfo", "u_mix", "u_win", "u_fft", "u_bsel", "u_chest", "u_nse", "u_post", "u_eq", "u_trk", "u_dec", "u_dm", "u_hdr", "u_deint", "u_ldpc",
          "u_desc", "u_pkt", "u_ca", "u_wc", "u_eq2", "u_rssi")


def load(name, default=None):
    f = RES / name
    return json.loads(f.read_text()) if f.exists() else default


def timing(path: Path) -> dict:
    t = path.read_text(errors="ignore") if path.exists() else ""
    m = re.search(r"WNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+\d+\s+\d+\s+(-?[\d.]+)\s+(-?[\d.]+)", t, re.S)
    return {"wns": float(m.group(1)), "tns": float(m.group(2)), "whs": float(m.group(3)), "ths": float(m.group(4))} if m else {}


def hier(path: Path) -> list:
    if not path.exists():
        return []
    seen, rows = set(), []
    for r in parse_hier(path):
        if r["inst"] in BLOCKS and r["inst"] not in seen:
            seen.add(r["inst"])
            rows.append({k: r[k] for k in ("inst", "lut", "ff", "bram36", "bram18", "dsp", "lutram")})
    return rows


def util(path: Path) -> dict:
    u = parse_util(path) if path.exists() else {}
    return {k: u.get(k) for k in ("lut", "ff", "bram", "dsp", "lutram")}


def impl(name: str) -> dict | None:
    d = RES / f"impl_{name}"
    if not (d / "reports_util.rpt").exists():
        return None
    h = hier(d / "reports_util_hier.rpt")
    phy = next((r for r in h if r["inst"] == "u_phy"), None)
    syn = [f for f in d.glob("*phy_rx*utilization_synth.rpt")]
    return {"total": util(d / "reports_util.rpt"), "timing": timing(d / "reports_timing.rpt"), "phy": phy, "hier": h,
            "phy_synth": util(syn[0]) if syn else None}


def ooc(d: Path) -> dict | None:
    if not (d / "phy_rx_top_util.rpt").exists():
        return None
    return {"util": util(d / "phy_rx_top_util.rpt"), "timing": timing(d / "phy_rx_top_timing.rpt"), "hier": hier(d / "phy_rx_top_util_hier.rpt")}


def regression(name: str) -> list:
    f = RES / name
    out = []
    if f.exists():
        for line in f.read_text(errors="ignore").splitlines():
            m = re.match(r"^(PASS|FAIL) (\S+)\s*(.*)$", line)
            if m:
                out.append({"name": m.group(2), "generic": m.group(3).strip(), "pass": m.group(1) == "PASS"})
    return out


data = {"study": load("study.json"), "diag": load("diag.json"), "det": load("det.json"), "rtl": load("rtl.json"),
        "impl": {n: impl(n) for n in ("baseline", "patch_a", "patch_b")},
        "impl_old": impl("baseline_before_mixer_fix"),
        "synth": {n: ooc(RES / f"synth_{n}") for n in ("baseline", "patch_a", "patch_b")},
        "opt": {"before": ooc(ROOT / "synth" / "out_final3"), "after": ooc(ROOT / "synth" / "out_opt2")},
        "regression": {"baseline": regression("regression_baseline.log"), "final": regression("regression_final.log")}}
tpl = (HERE / "rxenh_report_template.html").read_text(encoding="utf-8")
style = (HERE / "_dm_style.txt").read_text(encoding="utf-8")
OUT.write_text(tpl.replace("/*STYLE*/", style).replace("/*DATA*/null", json.dumps(data)), encoding="utf-8")
print("->", OUT, OUT.stat().st_size // 1024, "KB", {k: (v is not None) for k, v in data.items() if k in ("study", "diag", "det", "rtl")},
      {k: bool(v) for k, v in data["impl"].items()}, {k: bool(v) for k, v in data["synth"].items()})
