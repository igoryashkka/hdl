"""Python TX backend: the existing bit-exact fixed-point TX model (tx_ref.tx_frame) is the golden reference."""
from __future__ import annotations

import numpy as np

from .. import refs
from ..core.backend import TxBackend, register_tx


@register_tx("python")
class PythonTxBackend(TxBackend):
    def __init__(self):
        self.gain = 16384
        self.gap = 12000
        self.packets: list[bytes] = []
        self._starts: list[int] = []

    def configure(self, config: dict) -> None:
        self.gain = int(config["tx"].get("gain", 16384))
        self.gap = int(config["experiment"].get("packet_gap", 12000))

    def send(self, payload: list[bytes]) -> None:
        self.packets = [bytes(p) for p in payload]

    def get_iq(self) -> np.ndarray:
        parts, self._starts, pos = [], [], 0
        for k, p in enumerate(self.packets):
            iq = refs.tx_ref.tx_frame(list(p), gain=self.gain)
            frame = np.array([complex(a, b) for a, b in iq])
            self._starts.append(pos)
            parts.append(frame)
            pos += len(frame)
            if k != len(self.packets) - 1:
                parts.append(np.zeros(self.gap, complex))
                pos += self.gap
        return np.concatenate(parts) if parts else np.zeros(0, complex)

    def get_debug(self) -> dict:
        return {"packet_starts": list(self._starts), "samples_per_packet": [self._frame_len(p) for p in self.packets]}

    @staticmethod
    def _frame_len(p: bytes) -> int:
        nsym = -(-len(p) // refs.BYTES_PER_SYM)
        return (nsym + 2) * refs.SYM_LEN

    def reset(self) -> None:
        self.packets, self._starts = [], []
