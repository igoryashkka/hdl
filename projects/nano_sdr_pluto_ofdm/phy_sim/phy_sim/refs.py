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
SYNC_PEAK_OFFSET = SYM_LEN - 8
LTS_WINDOW_OFFSET = P.CP_LEN - 40       # FFT window of the LTS starts at n_best + 104 for CP = 144 (RTL W0_OFFSET)


hdr_ref = importlib.import_module("hdr_ref")

# phy.mode: "current" = legacy uncoded 16-QAM PHY (550 bytes / symbol, no header); every other value is the dual-mode frame
# [sync][LTS][header][data...]:  "max_range" = QPSK + LDPC 1/2 (MODE_ID 0), "max_rate" = 16-QAM + LDPC 5/6 (MODE_ID 1; "new" is an alias),
# "reference" = the reference PHY of ТЗ 003 (16-QAM + LDPC 5/6 + ZF + hard LLR + coarse synchronization only; set by the experiment through
# the phy.eq / phy.llr / phy.fine_timing / phy.sfo keys).  phy.layout = [modulation, code] overrides the layout (ablation study).
PHY_MODE_IDS = {"max_range": 0, "max_rate": 1, "new": 1, "reference": 1}


def phy_code(cfg: dict) -> str:
    """"ldpc" for the dual-mode PHY, "none" for the legacy uncoded PHY."""
    return "ldpc" if (cfg.get("phy") or {}).get("mode", "current") in PHY_MODE_IDS else "none"


def phy_layout(cfg: dict):
    """MODE_ID (0 / 1) or a (modulation, code) tuple of the coded frame."""
    ph = cfg.get("phy") or {}
    if ph.get("layout"):
        return tuple(ph["layout"])
    return PHY_MODE_IDS.get(ph.get("mode", "current"), 1)


_PHY_DEFAULTS = {
    "reference": {"eq": "zf", "llr": "hard", "fine_timing": False, "cpe": True, "sfo": False, "chest_smooth": 0},
}
_PHY_NEW = {"eq": "mmse", "llr": "weighted", "fine_timing": True, "cpe": True, "sfo": True, "chest_smooth": 1, "max_iter": 10}


def phy_opts(cfg: dict) -> dict:
    """Receiver options of the selected PHY mode (explicit keys of the phy section override the mode defaults).
    max_range / max_rate: MMSE + per-bin soft LLR + fine timing + CPE + SFO tracking + 9-bin channel smoothing (chest_smooth = 1 = half window, 3 bins);
    reference: ZF, hard-decision LDPC input, coarse timing only, no SFO tracking, LS channel estimate without smoothing."""
    ph = dict(cfg.get("phy") or {})
    base = dict(_PHY_NEW)
    base.update(_PHY_DEFAULTS.get(ph.get("mode", "max_rate"), {}))
    base.update({k: v for k, v in ph.items() if k != "mode"})
    return base


def bytes_per_sym(cfg: dict | None = None) -> int:
    return phy2_ref.info_bytes_per_sym(phy_layout(cfg)) if (cfg and phy_code(cfg) == "ldpc") else BYTES_PER_SYM


def frame_syms(cfg: dict | None = None) -> int:
    """OFDM symbols before the data: sync + LTS (+ header symbol of the dual-mode frame)."""
    return 3 if (cfg and phy_code(cfg) == "ldpc") else 2
