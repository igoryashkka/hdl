"""Builds the Current-vs-New PHY report (single HTML page) from results/compare/{compare,rtl_runs,resources}.json.
usage: python experiments/build_phy_report.py [resultsdir] [out.html]"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "results" / "compare"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else RES / "phy_report.html"

# Z7010 baseline (current PHY, v0.x builds, Vivado 2025.2)
BASE = {"tx": {"util": {"lut": 13264, "ff": 19021, "dsp": 55, "bram": 20}, "timing": {"wns": 0.521, "whs": 0.0, "fmax": 1000 / (8 - 0.521)}},
        "rx": {"util": {"lut": 13148, "ff": 16621, "dsp": 67, "bram": 30}, "timing": {"wns": 0.375, "whs": 0.011, "fmax": 1000 / (8 - 0.375)}}}

data = {"compare": json.loads((RES / "compare.json").read_text()),
        "rtl": json.loads((RES / "rtl_runs.json").read_text()),
        "res": json.loads((RES / "resources.json").read_text()),
        "base": BASE}
tpl = (HERE / "phy_report_template.html").read_text(encoding="utf-8")
OUT.write_text(tpl.replace("/*DATA*/null", json.dumps(data)), encoding="utf-8")
print("->", OUT, OUT.stat().st_size // 1024, "KB")
