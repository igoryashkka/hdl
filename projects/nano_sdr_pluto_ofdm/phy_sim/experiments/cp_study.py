"""CP optimisation experiment (ТЗ 003 section 15): CP = 144 / 256 / 384 samples, python models only (the RTL is built for CP = 144).
For every CP value a child process runs with PHY_CP_LEN set (phy_params reads it at import), measures SNR(PER <= 1 %) of MAX RANGE and
MAX RATE on channels with growing delay spread, and writes results/dualmode/cp_<CP>.json. The parent merges them into cp.json.
Overhead = CP / (2048 + CP); throughput = payload bytes per symbol * 8 * fs / (2048 + CP).
usage: python experiments/cp_study.py [--quick] [--procs N]            (parent)
       PHY_CP_LEN=256 python experiments/cp_study.py --child ...       (child, started by the parent)"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from multiprocessing import Pool
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

ECHOES = {"awgn": [], "echo40": [(40, -6)], "echo120": [(120, -6)], "echo200": [(200, -6)], "echo330": [(330, -6)],
          "mp3": [(10, -6), (25, -12)]}


def channel(cid):
    ec = ECHOES[cid]
    return {"multipath": [{"delay": 0, "gain_db": 0}] + [{"delay": d, "gain_db": g} for d, g in ec]} if ec else {}


def child(args):
    from dualmode_study import run_points, cfg_for, threshold   # noqa: E402  (imports phy_params with PHY_CP_LEN already set)
    from phy_params import CP_LEN
    out = {"cp": CP_LEN, "results": {}}
    n_coarse, n_fine = (1, 3) if args.quick else (3, 10)
    with Pool(args.procs or None) as pool:
        specs = {}
        for cid in ECHOES:
            specs[(cid, "max_range")] = ({"mode": "max_range", "timing": "twopass"}, channel(cid), 2, -4, 20)
            specs[(cid, "max_rate")] = ({"mode": "max_rate", "timing": "twopass"}, channel(cid), 2, 6, 36)
        from dualmode_study import study
        res = study(pool, specs, args.quick)
    for (cid, ph), pts in res.items():
        out["results"].setdefault(cid, {})[ph] = {"points": pts, "thr1": threshold(pts), "thr10": threshold(pts, 0.10)}
    Path(args.out, f"cp_{CP_LEN}.json").write_text(json.dumps(out, indent=1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--procs", type=int, default=0)
    ap.add_argument("--child", action="store_true")
    ap.add_argument("--out", default="results/dualmode")
    a = ap.parse_args()
    Path(a.out).mkdir(parents=True, exist_ok=True)
    if a.child:
        child(a)
        return
    t0 = time.time()
    merged = {}
    for cp in (144, 256, 384):
        env = dict(os.environ, PHY_CP_LEN=str(cp))
        cmd = [sys.executable, str(Path(__file__)), "--child", "--procs", str(a.procs), "--out", a.out] + (["--quick"] if a.quick else [])
        subprocess.run(cmd, env=env, check=True, cwd=str(HERE.parent))
        merged[str(cp)] = json.loads((Path(a.out) / f"cp_{cp}.json").read_text())
        print("CP", cp, "done", round(time.time() - t0), "s", flush=True)
    (Path(a.out) / "cp.json").write_text(json.dumps({"fs": 30.72e6, "bytes_per_sym": {"max_range": 135, "max_rate": 450}, "by_cp": merged}, indent=1))


if __name__ == "__main__":
    main()
