"""Built-in regression: runs every scenario in scenarios/ (or a list) and checks its pass/fail criteria (TZ section 18)."""
from __future__ import annotations

import json
from pathlib import Path

from ..core.config import deep_update
from ..core.experiment import run_experiment
from ..core.scenario import expand_sweep, load_scenario


def scenarios_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "scenarios"


def run_regression(files: list[Path] | None = None, outdir: str | Path | None = None, overrides: dict | None = None,
                   progress=print) -> tuple[bool, list[dict]]:
    files = files or sorted(p for p in scenarios_dir().glob("*.yaml") if not p.stem.endswith("_sweep"))
    results = []
    all_ok = True
    for f in files:
        raw = load_scenario(f)
        raw.pop("sweep", None)
        if overrides:
            raw = deep_update(raw, overrides)
        _, cfg = expand_sweep(raw)[0]
        od = Path(outdir) / cfg["experiment"]["name"] if outdir else None
        res = run_experiment(cfg, outdir=od, plots=bool(od))
        m = res.metrics
        status = "PASS" if res.passed else "FAIL"
        all_ok &= res.passed
        progress(f"{status}  {cfg['experiment']['name']:<22} BER={m['ber']:.3g} PER={m['per']:.3g} "
                 f"EVM={m.get('evm_rms_pct', float('nan')):.2f}% "
                 f"cfoErr={m.get('cfo_error_abs_max_hz', float('nan')):.0f}Hz tErr={m.get('timing_error_abs_max', float('nan')):.1f}")
        if not res.passed:
            for ln in res.criteria_lines:
                if ln.startswith("FAIL"):
                    progress("      " + ln)
        results.append({"name": cfg["experiment"]["name"], "passed": bool(res.passed), "metrics": {k: m.get(k) for k in
                        ("ber", "per", "evm_rms_pct", "cfo_error_abs_max_hz", "timing_error_abs_max")}})
    if outdir:
        Path(outdir).mkdir(parents=True, exist_ok=True)
        (Path(outdir) / "regression.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return all_ok, results
