"""Sample delay, fractional delay and sampling-frequency offset (TZ section 8)."""
import numpy as np


def lagrange4(x: np.ndarray, t: np.ndarray) -> np.ndarray:
    """4-point (cubic) Lagrange interpolation of x at fractional positions t (floats, in samples)."""
    i0 = np.floor(t).astype(np.int64)
    mu = t - i0
    xp = np.concatenate([np.zeros(2, x.dtype), x, np.zeros(3, x.dtype)])      # pad so indices i0-1 .. i0+2 are valid
    k = np.clip(i0 + 2, 1, len(xp) - 3)
    xm1, x0, x1, x2 = xp[k - 1], xp[k], xp[k + 1], xp[k + 2]
    c_m1 = -mu * (mu - 1) * (mu - 2) / 6
    c_0 = (mu + 1) * (mu - 1) * (mu - 2) / 2
    c_1 = -(mu + 1) * mu * (mu - 2) / 2
    c_2 = (mu + 1) * mu * (mu - 1) / 6
    return c_m1 * xm1 + c_0 * x0 + c_1 * x1 + c_2 * x2


def apply_delay(x: np.ndarray, integer: int = 0, fractional: float = 0.0) -> np.ndarray:
    """Delay by integer + fractional samples (output length = input length + integer + 1)."""
    total = integer + fractional
    n_out = len(x) + int(np.ceil(total)) + 1
    t = np.arange(n_out) - total
    y = lagrange4(x, t)
    y[(t < -1) | (t > len(x))] = 0
    return y


def apply_sfo(x: np.ndarray, ppm: float) -> np.ndarray:
    """Receiver sampling clock offset: y[n] = x(n*(1+ppm*1e-6)) (positive ppm = RX clock faster)."""
    t = np.arange(len(x)) * (1.0 + ppm * 1e-6)
    return lagrange4(x, t)
