"""Access to the existing Python golden models (tx_ref, rx_ref, rx_fixed_ref, sync_ref, ...) of the RTL project.

The framework does NOT re-implement them (ТЗ §21): this module only puts the reference directory on sys.path and
re-exports the modules. Override the location with the environment variable PHYSIM_REFS."""
import importlib
import os
import sys
from pathlib import Path


def refs_dir() -> Path:
    env = os.environ.get("PHYSIM_REFS")
    if env:
        return Path(env)
    # <repo>/projects/nano_sdr_pluto_ofdm/phy_sim/phy_sim/refs.py -> <repo>/projects/nano_sdr_pluto_ofdm/python
    return Path(__file__).resolve().parents[2] / "python"


def project_dir() -> Path:
    """Root of the RTL project (rtl/, tb/, sim/, python/)."""
    return refs_dir().parent


_p = str(refs_dir())
if _p not in sys.path:
    sys.path.insert(0, _p)

phy_params = importlib.import_module("phy_params")
tx_ref = importlib.import_module("tx_ref")
rx_ref = importlib.import_module("rx_ref")
rx_fixed_ref = importlib.import_module("rx_fixed_ref")
rx_blocks_ref = importlib.import_module("rx_blocks_ref")
sync_ref = importlib.import_module("sync_ref")
ofdm_ref = importlib.import_module("ofdm_ref")
qam_ref = importlib.import_module("qam_ref")
scrambler_ref = importlib.import_module("scrambler_ref")
interleaver_ref = importlib.import_module("interleaver_ref")
ldpc_ref = importlib.import_module("ldpc_ref")
ldpc_fixed_ref = importlib.import_module("ldpc_fixed_ref")
phy2_ref = importlib.import_module("phy2_ref")
phy2_fixed_ref = importlib.import_module("phy2_fixed_ref")

P = phy_params                          # shorthand: FFT_SIZE, CP_LEN, SAMPLE_RATE_HZ, ...
FS = float(P.SAMPLE_RATE_HZ)
N_FFT = P.FFT_SIZE
SYM_LEN = P.SYMBOL_LEN
BYTES_PER_SYM = P.BYTES_PER_OFDM
# calibration of the Schmidl-Cox detector (python/sync_test.py): sync-symbol start = n_best - SYNC_PEAK_OFFSET (+-20)
SYNC_PEAK_OFFSET = 2184
LTS_WINDOW_OFFSET = 104                 # FFT window of the LTS starts at n_best + 104 (RTL W0_OFFSET)


def phy_code(cfg: dict) -> str:
    """"ldpc" for the new PHY (LDPC R=5/6 + soft LLR + MMSE), "none" for the current uncoded PHY."""
    return "ldpc" if (cfg.get("phy") or {}).get("mode", "current") == "new" else "none"


def bytes_per_sym(cfg: dict | None = None) -> int:
    return phy2_ref.INFO_BYTES_PER_SYM if (cfg and phy_code(cfg) == "ldpc") else BYTES_PER_SYM
