"""Command line interface: python -m phy_sim run|sweep|replay|regression|report|unit (TZ section 24)."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from .core.config import deep_update, set_path
from .core.scenario import expand_sweep, load_scenario


def _apply_overrides(raw: dict, sets: list[str] | None) -> dict:
    for s in sets or []:
        k, v = s.split("=", 1)
        val = json.loads(v) if v[:1] in "[{\"-0123456789" or v in ("true", "false", "null") else v
        set_path(raw, k, val)
    return raw


def _scenario_path(arg: str) -> Path:
    p = Path(arg)
    if p.exists():
        return p
    from .core.regression import scenarios_dir
    q = scenarios_dir() / (arg if arg.endswith(".yaml") else arg + ".yaml")
    if q.exists():
        return q
    raise FileNotFoundError(f"scenario '{arg}' not found")


def cmd_run(a) -> int:
    from .core.experiment import run_experiment
    raw = _apply_overrides(load_scenario(_scenario_path(a.scenario)), a.set)
    if a.tx:
        raw.setdefault("tx", {})["backend"] = a.tx
    if a.rx:
        raw.setdefault("rx", {})["backend"] = a.rx
    raw.pop("sweep", None)
    _, cfg = expand_sweep(raw)[0]
    out = Path(a.out or Path("results") / cfg["experiment"]["name"])
    res = run_experiment(cfg, outdir=out)
    m = res.metrics
    print(f"{'PASS' if res.passed else 'FAIL'}   {cfg['experiment']['name']}  (TX {m['tx_backend']} -> RX {m['rx_backend']} {m['rx_mode'] or ''})")
    for k in ("ber", "ser", "per", "evm_rms_pct", "mer_db", "papr_db", "cfo_error_abs_max_hz", "timing_error_abs_max", "channel_est_mse_db"):
        if m.get(k) is not None:
            print(f"  {k:<24} {m[k]:.6g}")
    for ln in res.criteria_lines:
        print("  " + ln)
    print(f"results: {out}")
    return 0 if res.passed else 1


def cmd_sweep(a) -> int:
    from .core.sweep import run_sweep
    raw = _apply_overrides(load_scenario(_scenario_path(a.scenario)), a.set)
    if a.tx:
        raw.setdefault("tx", {})["backend"] = a.tx
    if a.rx:
        raw.setdefault("rx", {})["backend"] = a.rx
    out = Path(a.out or Path("results") / (raw["experiment"]["name"] + "_sweep"))
    run_sweep(raw, out, trials=a.trials, keep_runs=a.keep_runs)
    print(f"sweep results: {out}")
    return 0


def cmd_replay(a) -> int:
    from .core.replay import replay
    over = {}
    if a.rx:
        over["rx"] = {"backend": a.rx}
    res = replay(a.path, outdir=a.out, overrides=over)
    m = res.metrics
    print(f"{'PASS' if res.passed else 'FAIL'}  replay {a.path}: BER={m['ber']:.3g} PER={m['per']:.3g} "
          f"packets {m['packets_received']}/{m['packets_transmitted']}")
    return 0 if res.passed else 1


def cmd_regression(a) -> int:
    from .core.regression import run_regression
    over = {}
    if a.rx:
        over["rx"] = {"backend": a.rx}
    if a.tx:
        over["tx"] = {"backend": a.tx}
    files = [_scenario_path(s) for s in a.scenarios] if a.scenarios else None
    ok, _ = run_regression(files, outdir=a.out, overrides=over)
    print("REGRESSION", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_report(a) -> int:
    d = Path(a.path)
    m = json.loads((d / "metrics.json").read_text(encoding="utf-8"))
    print(json.dumps({k: v for k, v in m.items() if not isinstance(v, (dict, list))}, indent=2))
    html = d / "report.html"
    if html.exists():
        print(f"report: {html}")
        if a.open:
            import webbrowser
            webbrowser.open(html.resolve().as_uri())
    return 0


def cmd_unit(a) -> int:
    """Level 1/2 validation: run the unit / block / system testbenches of the RTL project (sim/run_regression.sh)."""
    from . import refs
    script = refs.project_dir() / "sim" / "run_regression.sh"
    return subprocess.call(["bash", str(script)], cwd=str(refs.project_dir()))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="phy_sim", description="OFDM PHY validation framework (Python models / RTL simulation / hardware)")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, out=True):
        sp.add_argument("--tx", help="override tx backend (python|rtl|pluto)")
        sp.add_argument("--rx", help="override rx backend (python|python:float|rtl|pluto)")
        sp.add_argument("--set", action="append", help="override a config value: section.key=value (JSON value)")
        if out:
            sp.add_argument("--out", help="output directory")

    sp = sub.add_parser("run", help="run one scenario"); sp.add_argument("scenario"); common(sp); sp.set_defaults(fn=cmd_run)
    sp = sub.add_parser("sweep", help="parameter sweep"); sp.add_argument("scenario"); common(sp)
    sp.add_argument("--trials", type=int); sp.add_argument("--keep-runs", action="store_true"); sp.set_defaults(fn=cmd_sweep)
    sp = sub.add_parser("replay", help="replay a captured IQ trace"); sp.add_argument("path")
    sp.add_argument("--rx"); sp.add_argument("--out"); sp.set_defaults(fn=cmd_replay)
    sp = sub.add_parser("regression", help="run the scenario regression"); sp.add_argument("scenarios", nargs="*")
    sp.add_argument("--tx"); sp.add_argument("--rx"); sp.add_argument("--out"); sp.set_defaults(fn=cmd_regression)
    sp = sub.add_parser("report", help="show / open a stored report"); sp.add_argument("path")
    sp.add_argument("--open", action="store_true"); sp.set_defaults(fn=cmd_report)
    sp = sub.add_parser("unit", help="run the RTL block/system testbench regression (xsim)"); sp.set_defaults(fn=cmd_unit)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
