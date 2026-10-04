import numpy as np

from phy_sim.core.backend import make_tx
from phy_sim.core.config import build_config
from phy_sim.core.experiment import run_experiment
from phy_sim.phy import golden


def _cfg(**kw):
    return build_config(kw)


def test_python_tx_matches_golden():
    cfg = _cfg(payload={"nsyms": 2})
    pay = bytes(range(256)) * 5 + bytes(100)
    tx = make_tx("python")
    tx.configure(cfg)
    tx.send([pay])
    assert np.array_equal(tx.get_iq(), golden.tx_iq(pay))


def test_python_loopback_perfect_channel():
    res = run_experiment(_cfg(channel={"snr_db": 45}, criteria={"max_ber": 0, "max_per": 0}))
    assert res.passed and res.metrics["packets_received"] == 1


def test_float_and_fixed_receivers_decode():
    for mode in ("fixed", "float"):
        cfg = _cfg(channel={"snr_db": 40, "cfo_hz": 4000}, rx={"backend": "python", "mode": mode}, criteria={"max_ber": 0})
        assert run_experiment(cfg).passed, mode


def test_cfo_estimate_accuracy():
    res = run_experiment(_cfg(channel={"snr_db": 30, "cfo_hz": -9000}))
    assert res.metrics["cfo_error_abs_max_hz"] < 100
