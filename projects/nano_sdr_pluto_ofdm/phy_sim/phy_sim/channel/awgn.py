"""AWGN with SNR / Es/N0 / Eb/N0 definitions (TZ section 8)."""
import numpy as np

from .. import refs

N_ACTIVE = refs.P.NUM_ACTIVE_SC
N_DATA = refs.P.NUM_DATA_SC
BITS_PER_SYM = refs.P.BITS_PER_SYM


def snr_sample_db(value_db: float, definition: str = "sample") -> float:
    """Convert a user SNR to the per-sample (full 30.72 MHz band) SNR used to scale the noise.
    sample: noise power / signal power per time-domain sample.
    esn0  : Es/N0 per active subcarrier: Es/N0 = SNR_sample + 10log10(N_FFT/N_active).
    ebn0  : Eb/N0 = Es/N0 - 10log10(bits_per_symbol * N_data/N_active)  (uncoded, pilots counted as overhead)."""
    d = definition.lower()
    if d == "sample":
        return value_db
    esn0_to_sample = -10 * np.log10(refs.N_FFT / N_ACTIVE)
    if d == "esn0":
        return value_db + esn0_to_sample
    if d == "ebn0":
        return value_db + 10 * np.log10(BITS_PER_SYM * N_DATA / N_ACTIVE) + esn0_to_sample
    raise ValueError(f"unknown snr_definition '{definition}'")


def add_awgn(x: np.ndarray, snr_db: float, rng: np.random.Generator, sig_power: float | None = None) -> np.ndarray:
    """x: complex. sig_power: reference signal power (default: mean |x|^2 over non-zero samples)."""
    if sig_power is None:
        nz = np.abs(x) > 0
        sig_power = float(np.mean(np.abs(x[nz]) ** 2)) if nz.any() else 1.0
    npow = sig_power / (10 ** (snr_db / 10))
    n = np.sqrt(npow / 2) * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    return x + n
