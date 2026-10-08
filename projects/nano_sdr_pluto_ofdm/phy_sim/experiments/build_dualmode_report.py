"""Builds the dual-mode PHY report (single HTML page) from results/dualmode/{study,cp,header,scenario,rtl}.json.
usage: python experiments/build_dualmode_report.py [resultsdir] [out.html]"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "results" / "dualmode"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else RES / "dualmode_report.html"


def load(name, default=None):
    f = RES / name
    return json.loads(f.read_text()) if f.exists() else default


study = load("study.json")
data = {"study": study, "cp": load("cp.json"), "header": load("header.json", {}), "scenario": load("scenario.json", {}), "rtl": load("rtl.json")}
study["ablation_nsyms"] = 4
tpl = (HERE / "dualmode_report_template.html").read_text(encoding="utf-8")
style = (HERE / "_dm_style.txt").read_text(encoding="utf-8")
OUT.write_text(tpl.replace("/*STYLE*/", style).replace("/*DATA*/null", json.dumps(data)), encoding="utf-8")
print("->", OUT, OUT.stat().st_size // 1024, "KB")
