"""Demodulation and OFDM metrics (TZ sections 15, 16)."""
from __future__ import annotations

import numpy as np
from scipy import signal

from .. import refs
from ..phy import golden


# ------------------------------------------------------------------ error counting
def bit_errors(tx: bytes, rx: bytes) -> tuple[int, int]:
    n = len(tx)
    rxp = bytes(rx[:n]) + bytes(max(0, n - len(rx)))
    a = np.unpackbits(np.frombuffer(bytes(tx), dtype=np.uint8))
    b = np.unpackbits(np.frombuffer(rxp, dtype=np.uint8))
    return int(np.sum(a != b)), int(a.size)


def symbol_errors(tx: bytes, rx: bytes) -> tuple[int, int]:
    """16-QAM symbol errors: both byte streams are pushed through the TX scramble/interleave/map chain and compared."""
    tp = golden.pad_to_symbols(tx)
    rp = golden.pad_to_symbols(bytes(rx[:len(tp)]) + bytes(max(0, len(tp) - len(rx))))
    st, _ = golden.tx_data_symbols(tp)
    sr, _ = golden.tx_data_symbols(rp)
    return int(np.sum(st != sr)), int(st.size)


# ------------------------------------------------------------------ constellation quality
def evm(rx_syms: np.ndarray, ref_syms: np.ndarray) -> dict:
    """rx/ref: complex arrays of equal shape. A single complex gain is fitted (removes constant gain / phase)."""
    r = np.asarray(rx_syms).ravel()
    s = np.asarray(ref_syms).ravel()
    g = np.vdot(s, r) / np.vdot(s, s)
    e = r / g - s
    p_ref = np.mean(np.abs(s) ** 2)
    rms = np.sqrt(np.mean(np.abs(e) ** 2) / p_ref)
    peak = np.max(np.abs(e)) / np.sqrt(p_ref)
    return {"evm_rms_pct": float(100 * rms), "evm_peak_pct": float(100 * peak),
            "mer_db": float(-20 * np.log10(max(rms, 1e-12))), "gain": complex(g)}


def subcarrier_snr_db(rx_syms: np.ndarray, ref_syms: np.ndarray) -> np.ndarray:
    """Per data-subcarrier SNR from (nsym, nsc) arrays (needs several symbols to be meaningful)."""
    r = np.atleast_2d(rx_syms)
    s = np.atleast_2d(ref_syms)
    g = np.vdot(s, r) / np.vdot(s, s)
    e = r / g - s
    return 10 * np.log10(np.mean(np.abs(s) ** 2, axis=0) / np.maximum(np.mean(np.abs(e) ** 2, axis=0), 1e-12))


# ------------------------------------------------------------------ waveform metrics
def papr_db(iq: np.ndarray) -> float:
    x = np.asarray(iq)
    x = x[np.abs(x) > 0]
    return float(10 * np.log10(np.max(np.abs(x) ** 2) / np.mean(np.abs(x) ** 2)))


def crest_factor_db(iq: np.ndarray) -> float:
    return float(papr_db(iq) / 2.0)          # amplitude crest factor in dB = PAPR/2 (dB of power ratio -> amplitude)


def psd(iq: np.ndarray, fs: float = refs.FS, nperseg: int = 4096):
    f, p = signal.welch(np.asarray(iq, dtype=np.complex128), fs=fs, nperseg=nperseg, return_onesided=False, scaling="density")
    o = np.argsort(f)
    return f[o], p[o]


def occupied_bandwidth_hz(iq: np.ndarray, fs: float = refs.FS, fraction: float = 0.99) -> float:
    f, p = psd(iq, fs)
    c = np.cumsum(p) / np.sum(p)
    lo = f[np.searchsorted(c, (1 - fraction) / 2)]
    hi = f[np.searchsorted(c, 1 - (1 - fraction) / 2)]
    return float(hi - lo)


# ------------------------------------------------------------------ OFDM metrics
def cpe_stats(angles: np.ndarray) -> dict:
    """angles: CPE angle per symbol in 2^32 = 2*pi units (RTL/fixed model) -> radians."""
    if angles is None or len(angles) == 0:
        return {}
    a = np.asarray(angles, dtype=np.int64)
    a = np.where(a >= 2 ** 31, a - 2 ** 32, a).astype(np.float64) * 2 * np.pi / 2 ** 32
    return {"cpe_rad_mean": float(a.mean()), "cpe_rad_std": float(a.std()), "cpe_rad_max": float(np.max(np.abs(a)))}


def null_bin_ratio_db(iq: np.ndarray, symbol_body_starts: list[int]) -> float:
    """ICI / leakage proxy: power in the unused (null) FFT bins relative to the active bins, averaged over symbol bodies."""
    n = refs.N_FFT
    act = refs.rx_ref.ACTIVE_BINS
    mask = np.ones(n, bool)
    mask[act] = False
    mask[0] = False
    # exclude bins right at the band edge (spectral skirt of the OFDM spectrum itself)
    for b in list(range(refs.P.NUM_POS_SC + 1, refs.P.NUM_POS_SC + 101)) + list(range(refs.P.NEG_FIRST_BIN - 100, refs.P.NEG_FIRST_BIN)):
        mask[b] = False
    num = den = 0.0
    for s in symbol_body_starts:
        if s < 0 or s + n > len(iq):
            continue
        X = np.fft.fft(iq[s:s + n])
        num += np.mean(np.abs(X[mask]) ** 2)
        den += np.mean(np.abs(X[act]) ** 2)
    if den == 0:
        return float("nan")
    return float(10 * np.log10(max(num, 1e-30) / den))
