"""Pluto / AD9361 hardware backends (TZ section 23, level 4) -- UNTESTED skeleton.

These classes use the standard pyadi-iio interface (`pip install pyadi-iio`) with the stock Pluto firmware (IQ over USB), which is
the way to run the *Python* PHY over real RF. Driving the custom PL builds (nano_sdr_pluto_ofdm_tx / _rx, packets over DMA) needs a
small C/Python packetizer on the PS and is not covered here. Nothing in this module has been executed against hardware yet."""
from __future__ import annotations

import numpy as np

from ...core.backend import RxBackend, TxBackend, register_rx, register_tx


def _sdr(cfg: dict):
    try:
        import adi  # type: ignore
    except ImportError as e:  # pragma: no cover
        raise RuntimeError("pyadi-iio is required for the Pluto backend: pip install pyadi-iio") from e
    h = cfg.get("hardware", {})
    sdr = adi.Pluto(uri=h.get("uri", "ip:192.168.2.1"))
    sdr.sample_rate = int(30.72e6)
    sdr.rx_lo = sdr.tx_lo = int(h.get("fc_hz", 2.4e9))
    sdr.rx_rf_bandwidth = sdr.tx_rf_bandwidth = int(20e6)
    sdr.tx_hardwaregain_chan0 = float(h.get("tx_gain_db", -10))
    sdr.gain_control_mode_chan0 = h.get("rx_agc", "slow_attack")
    return sdr


@register_tx("pluto")
class PlutoTxBackend(TxBackend):
    def __init__(self):
        self.cfg, self.iq, self.sdr = {}, np.zeros(0, complex), None

    def configure(self, config: dict) -> None:
        self.cfg = config

    def send(self, payload):
        from ...phy.python_tx import PythonTxBackend
        py = PythonTxBackend(); py.configure(self.cfg); py.send(payload)
        self.iq = py.get_iq()
        self._dbg = py.get_debug()

    def get_iq(self) -> np.ndarray:
        return self.iq

    def get_debug(self) -> dict:
        return getattr(self, "_dbg", {})

    def transmit(self, cyclic: bool = True) -> None:  # pragma: no cover - hardware
        self.sdr = self.sdr or _sdr(self.cfg)
        self.sdr.tx_cyclic_buffer = cyclic
        self.sdr.tx(self.iq * (2 ** 14 / max(np.max(np.abs(self.iq)), 1)))


@register_rx("pluto")
class PlutoRxBackend(RxBackend):
    def __init__(self):
        self.cfg, self.sdr, self.inner = {}, None, None

    def configure(self, config: dict) -> None:
        self.cfg = config

    def process(self, iq=None) -> None:  # pragma: no cover - hardware
        """Captures `rx.capture_samples` samples from the radio (the `iq` argument is ignored) and decodes them with the Python PHY."""
        from ...phy.python_rx import PythonRxBackend
        self.sdr = self.sdr or _sdr(self.cfg)
        n = int(self.cfg["rx"].get("capture_samples", 2 ** 18))
        self.sdr.rx_buffer_size = n
        rx = self.sdr.rx()
        self.inner = PythonRxBackend(); self.inner.configure(self.cfg)
        self.inner.process(np.asarray(rx))

    def get_payload(self):
        return self.inner.get_payload() if self.inner else []

    def get_debug(self):
        return self.inner.get_debug() if self.inner else {}
