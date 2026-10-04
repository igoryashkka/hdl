"""Doppler / Clarke-Jakes time-varying complex gain (sum of sinusoids) (TZ section 8)."""
import numpy as np


def jakes_gain(n: int, doppler_hz: float, fs: float, rng: np.random.Generator, n_sin: int = 32) -> np.ndarray:
    """Unit-power complex Gaussian process with Clarke spectrum (max Doppler `doppler_hz`)."""
    if doppler_hz <= 0:
        # static complex Gaussian tap (Rayleigh with zero Doppler)
        g = (rng.standard_normal() + 1j * rng.standard_normal()) / np.sqrt(2)
        return np.full(n, g)
    t = np.arange(n) / fs
    alpha = rng.uniform(0, 2 * np.pi, n_sin)
    phi = rng.uniform(0, 2 * np.pi, n_sin)
    g = np.zeros(n, dtype=np.complex128)
    for a, p in zip(alpha, phi):
        g += np.exp(1j * (2 * np.pi * doppler_hz * np.cos(a) * t + p))
    return g / np.sqrt(n_sin)
