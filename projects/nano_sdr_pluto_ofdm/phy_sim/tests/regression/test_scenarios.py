import pytest

from phy_sim.core.experiment import run_experiment
from phy_sim.core.regression import scenarios_dir
from phy_sim.core.scenario import expand_sweep, load_scenario

SCEN = sorted(p for p in scenarios_dir().glob("*.yaml") if not p.stem.endswith("_sweep"))


@pytest.mark.parametrize("path", SCEN, ids=[p.stem for p in SCEN])
def test_scenario_python(path):
    raw = load_scenario(path)
    raw.pop("sweep", None)
    _, cfg = expand_sweep(raw)[0]
    cfg["tx"]["backend"] = "python"
    cfg["rx"] = {**cfg["rx"], "backend": "python", "mode": "fixed"}
    res = run_experiment(cfg)
    assert res.passed, "\n".join(res.criteria_lines)


@pytest.mark.rtl
def test_full_loopback_all_backend_combinations():
    raw = load_scenario(scenarios_dir() / "full_loopback.yaml")
    _, base = expand_sweep(raw)[0]
    for tx in ("python", "rtl"):
        for rx in ("python", "rtl"):
            cfg = {**base, "tx": {**base["tx"], "backend": tx}, "rx": {**base["rx"], "backend": rx}}
            res = run_experiment(cfg)
            assert res.passed, f"{tx}->{rx}: " + "\n".join(res.criteria_lines)


@pytest.mark.rtl
def test_rtl_rx_matches_python_fixed_model():
    raw = load_scenario(scenarios_dir() / "cfo.yaml")
    _, cfg = expand_sweep(raw)[0]
    cfg["rx"] = {**cfg["rx"], "backend": "rtl", "compare_with": ["python:fixed"]}
    res = run_experiment(cfg)
    assert res.metrics["comparison"]["python:fixed"]["ok"]
