"""RF channel model chain (TZ section 8): iq_rx = channel.process(iq_tx).

Order: PA nonlinearity -> multipath | fading -> delay / fractional delay / sampling offset -> phase noise -> CFO ->
IQ imbalance -> interference -> AWGN -> ADC (AGC scale, DC offset, quantisation, clipping).
The ground truth of everything that was applied is returned alongside the signal (TZ section 9)."""
from __future__ import annotations

import numpy as np

from .. import refs
from . import adc, awgn, cfo, fading, interference, iq_imbalance, multipath, nonlinear, phase_noise, timing


class Channel:
    def __init__(self, cfg: dict, fs: float = refs.FS):
        self.cfg = cfg
        self.fs = fs
        self._taps_static: list[tuple[int, complex]] = []
        self._taps_fading: list[tuple[int, np.ndarray]] = []

    # ------------------------------------------------------------------ main entry
    def process(self, iq_tx: np.ndarray, rng: np.random.Generator):
        c = self.cfg
        x = np.asarray(iq_tx, dtype=np.complex128)
        truth: dict = {"fs": self.fs}

        if c.get("pa"):
            x = nonlinear.apply_pa(x, c["pa"])
            truth["pa"] = c["pa"]

        first_tap = 0
        self._taps_static, self._taps_fading = [], []
        if c.get("fading"):
            x, taps = fading.apply_fading(x, c["fading"], self.fs, rng)
            self._taps_fading = taps
            first_tap = min(d for d, _ in taps)
            truth["fading"] = c["fading"]
        elif c.get("multipath"):
            taps = multipath.taps_from_config(c["multipath"])
            x = multipath.apply_multipath(x, taps)
            self._taps_static = taps
            first_tap = min(d for d, _ in taps)
            truth["multipath"] = [(d, complex(g)) for d, g in taps]

        tshift = int(c.get("timing_offset", 0))
        frac = float(c.get("fractional_delay", 0.0))
        if tshift or frac:
            x = timing.apply_delay(x, tshift, frac)
        if float(c.get("sfo_ppm", 0.0)) != 0.0:
            x = timing.apply_sfo(x, float(c["sfo_ppm"]))
        truth["delay_samples"] = first_tap + tshift + frac
        truth["timing_offset"] = tshift
        truth["fractional_delay"] = frac
        truth["sfo_ppm"] = float(c.get("sfo_ppm", 0.0))

        if c.get("phase_noise"):
            x, ph = phase_noise.apply_phase_noise(x, c["phase_noise"], self.fs, rng)
            truth["phase_noise_cfg"] = c["phase_noise"]
        cfo_hz = float(c.get("cfo_hz", 0.0))
        if cfo_hz or c.get("phase0_deg"):
            x = cfo.apply_cfo(x, cfo_hz, float(c.get("phase0_deg", 0.0)), self.fs)
        truth["cfo_hz"] = cfo_hz

        if c.get("iq_imbalance"):
            x = iq_imbalance.apply_iq_imbalance(x, float(c["iq_imbalance"].get("gain_db", 0.0)),
                                                float(c["iq_imbalance"].get("phase_deg", 0.0)))
            truth["iq_imbalance"] = c["iq_imbalance"]

        if c.get("interference"):
            x = interference.add_interference(x, c["interference"], self.fs, rng)
            truth["interference"] = c["interference"]

        sig_power = float(np.mean(np.abs(x[np.abs(x) > 0]) ** 2)) if np.any(x) else 1.0
        truth["signal_power"] = sig_power
        if c.get("snr_db") is not None:
            snr_s = awgn.snr_sample_db(float(c["snr_db"]), c.get("snr_definition", "sample"))
            x = awgn.add_awgn(x, snr_s, rng, sig_power)
            truth["snr_db"] = float(c["snr_db"])
            truth["snr_sample_db"] = snr_s
            truth["snr_definition"] = c.get("snr_definition", "sample")

        a = c.get("adc") or {}
        if a.get("enabled", True):
            x, info = adc.apply_adc(x, a)
            truth["adc"] = info
        return x, truth

    # ------------------------------------------------------------------ ground-truth channel response
    def frequency_response(self, bins: np.ndarray, at_index: int | None = None) -> np.ndarray:
        """True H[k] for FFT bins (relative to the direct path delay). Fading taps are evaluated at sample `at_index`."""
        n = refs.N_FFT
        if self._taps_fading:
            i = 0 if at_index is None else min(max(at_index, 0), len(self._taps_fading[0][1]) - 1)
            taps = [(d, complex(g[i])) for d, g in self._taps_fading]
        elif self._taps_static:
            taps = self._taps_static
        else:
            return np.ones(len(bins), complex)
        return multipath.frequency_response(taps, np.asarray(bins), n)
