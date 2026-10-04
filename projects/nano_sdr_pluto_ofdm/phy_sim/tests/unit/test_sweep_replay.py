import json

from phy_sim.core.config import build_config
from phy_sim.core.experiment import run_experiment
from phy_sim.core.replay import replay
from phy_sim.core.scenario import expand_sweep
from phy_sim.core.sweep import run_sweep


def test_sweep_expansion_and_run(tmp_path):
    raw = {"experiment": {"name": "t"}, "payload": {"nsyms": 1}, "sweep": {"snr_db": {"values": [20, 30]}, "cfo_hz": {"values": [0, 3000]}}}
    assert len(expand_sweep(raw)) == 4
    res = run_sweep(raw, tmp_path)
    assert len(res["rows"]) == 4 and (tmp_path / "heatmap_ber.png").exists()


def test_replay_reproduces_result(tmp_path):
    cfg = build_config({"channel": {"snr_db": 35, "cfo_hz": 3000}, "criteria": {"max_ber": 0}})
    res = run_experiment(cfg, outdir=tmp_path / "run", plots=False)
    assert res.passed
    rep = replay(tmp_path / "run" / "capture")
    assert rep.metrics["ber"] == 0 and rep.metrics["packets_received"] == 1
    assert json.loads((tmp_path / "run" / "metrics.json").read_text())["passed"]
