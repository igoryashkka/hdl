"""Builds results/study/report.html from study.json + report_template.html."""
import json, sys
from pathlib import Path
here = Path(__file__).resolve().parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "results" / "study" / "study.json"
data = json.loads(src.read_text())
html = (here / "report_template.html").read_text(encoding="utf-8").replace("/*DATA*/null", json.dumps(data, separators=(",", ":")))
out = src.with_name("report.html")
out.write_text(html, encoding="utf-8")
print(out, len(html))
