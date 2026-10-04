"""Backend API (ТЗ §3, §4): the experiment never knows where the PHY runs (Python model, RTL simulation, hardware)."""
from __future__ import annotations

from abc import ABC, abstractmethod

import numpy as np


class TxBackend(ABC):
    name = "tx"

    @abstractmethod
    def configure(self, config: dict) -> None: ...

    @abstractmethod
    def send(self, payload: list[bytes]) -> None:
        """Queue packets (each one a bytes object, multiple of 550 bytes) for transmission."""

    @abstractmethod
    def get_iq(self) -> np.ndarray:
        """Complex IQ (int-valued, 30.72 MS/s) of all queued packets, packets separated by `packet_gap` zero samples."""

    def get_debug(self) -> dict:
        return {}

    def reset(self) -> None: ...


class RxBackend(ABC):
    name = "rx"

    @abstractmethod
    def configure(self, config: dict) -> None: ...

    @abstractmethod
    def process(self, iq: np.ndarray) -> None:
        """Feed ADC-level complex IQ (int-valued) and run the receiver over the whole stream."""

    @abstractmethod
    def get_payload(self) -> list[bytes]:
        """Decoded packets in order of arrival."""

    def get_debug(self) -> dict:
        """Optional: events (n_best, cfo_inc), equalized symbols (per packet), channel weights, timing, ..."""
        return {}

    def reset(self) -> None: ...


_TX: dict[str, type] = {}
_RX: dict[str, type] = {}


def register_tx(name: str):
    def deco(cls):
        _TX[name] = cls
        cls.name = name
        return cls
    return deco


def register_rx(name: str):
    def deco(cls):
        _RX[name] = cls
        cls.name = name
        return cls
    return deco


def make_tx(name: str) -> TxBackend:
    _load_backends()
    if name not in _TX:
        raise KeyError(f"unknown tx backend '{name}' (available: {sorted(_TX)})")
    return _TX[name]()


def make_rx(name: str) -> RxBackend:
    _load_backends()
    if name not in _RX:
        raise KeyError(f"unknown rx backend '{name}' (available: {sorted(_RX)})")
    return _RX[name]()


def _load_backends():
    # importing the modules registers the backends
    from ..phy import python_tx, python_rx  # noqa: F401
    from ..rtl.xsim import tx as _xtx, rx as _xrx  # noqa: F401
    from ..rtl.hardware import pluto  # noqa: F401
