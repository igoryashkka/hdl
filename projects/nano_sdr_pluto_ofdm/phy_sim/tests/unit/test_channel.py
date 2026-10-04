import numpy as np

from phy_sim.analysis import statistics as st
from phy_sim.channel import adc, awgn, cfo, fading, iq_imbalance, multipath, nonlinear, phase_noise, timing


def rng():
    return np.random.default_rng(0)


def test_awgn_snr_definitions():
    x = np.exp(2j * np.pi * 0.01 * np.arange(200000))
    y = awgn.add_awgn(x, 10.0, rng())
    meas = 10 * np.log10(1 / np.mean(np.abs(y - x) ** 2))
    assert abs(meas - 10.0) < 0.1
    assert abs(awgn.snr_sample_db(20, "esn0") - (20 - 10 * np.log10(2048 / 1200))) < 1e-9
    assert awgn.snr_sample_db(20, "ebn0") > awgn.snr_sample_db(20, "esn0") - 10


def test_cfo_phase_ramp():
    y = cfo.apply_cfo(np.ones(1000, complex), 15000.0, fs=30.72e6)
    assert abs(np.angle(y[1] / y[0]) - 2 * np.pi * 15000 / 30.72e6) < 1e-9


def test_integer_and_fractional_delay():
    x = np.zeros(64, complex)
    x[10] = 1
    y = timing.apply_delay(x, 5, 0.0)
    assert np.argmax(np.abs(y)) == 15
    f = timing.apply_delay(np.sin(2 * np.pi * 0.02 * np.arange(200)).astype(complex), 0, 0.5)
    ref = np.sin(2 * np.pi * 0.02 * (np.arange(len(f)) - 0.5))
    assert np.max(np.abs(f[10:190].real - ref[10:190])) < 5e-3


def test_sfo_resampling():
    x = np.exp(2j * np.pi * 0.01 * np.arange(1000))
    y = timing.apply_sfo(x, 1000.0)
    assert abs(y[900] - np.exp(2j * np.pi * 0.01 * 900 * 1.001)) < 1e-3


def test_multipath_response_matches_fft_of_taps():
    taps = [(0, 1 + 0j), (7, 0.5j)]
    h = multipath.frequency_response(taps, np.arange(2048), 2048)
    ref = np.fft.fft([1] + [0] * 6 + [0.5j] + [0] * 2040)
    assert np.allclose(h, ref)


def test_rayleigh_power():
    g, _ = fading.apply_fading(np.ones(100000, complex), {"type": "rayleigh", "doppler_hz": 50, "delays": [0]}, 30.72e6, rng())
    assert 0.3 < np.mean(np.abs(g[:100000]) ** 2) < 3.0


def test_iq_imbalance_image():
    n = np.arange(4096)
    x = np.exp(2j * np.pi * 0.1 * n)
    y = iq_imbalance.apply_iq_imbalance(x, 1.0, 5.0)
    X = np.abs(np.fft.fft(y))
    assert X[int(0.9 * 4096)] > 1e-3 * X[int(0.1 * 4096)]          # image tone appears


def test_pa_compression_and_adc_clip():
    x = np.linspace(0.1, 10, 100) + 0j
    y = nonlinear.apply_pa(x, {"ibo_db": 0.0, "smoothness": 3})
    assert np.abs(y[-1]) < np.abs(x[-1])
    q, info = adc.apply_adc(np.array([100.0 + 0j, -5000 + 0j, 3 + 1j]), {"bits": 12, "rms": 1e9, "clip": True})
    assert np.max(q.real) <= 2047 and np.min(q.real) >= -2048 and info["clipped_fraction"] > 0


def test_phase_noise_wiener_variance():
    _, ph = phase_noise.apply_phase_noise(np.ones(200000, complex), {"linewidth_hz": 1000.0}, 30.72e6, rng())
    assert 0.3 < np.var(np.diff(ph)) / (2 * np.pi * 1000.0 / 30.72e6) < 3.0


def test_metrics_evm_and_errors():
    s = np.array([1 + 1j, -1 + 1j, 1 - 1j, -1 - 1j] * 50, complex)
    e = st.evm(s * (0.5 + 0.2j) * (1 + 0.05 * np.random.default_rng(1).standard_normal(s.size)), s)
    assert 3 < e["evm_rms_pct"] < 8
    assert st.bit_errors(b"\x00\xff", b"\x01\xff") == (1, 16)
