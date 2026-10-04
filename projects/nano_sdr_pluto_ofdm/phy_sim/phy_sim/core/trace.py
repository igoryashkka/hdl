"""Central signal recorder (ТЗ §10) with replayable on-disk format (.npz + trace.json)."""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np


@dataclass
class TraceItem:
    name: str
    data: np.ndarray
    dtype: str
    shape: tuple
    sample_rate: float | None
    frequency: float | None
    timestamp: float
    source: str
    metadata: dict = field(default_factory=dict)


class Trace:
    def __init__(self):
        self.items: dict[str, TraceItem] = {}

    def record(self, name: str, data, *, sample_rate: float | None = None, frequency: float | None = None,
               source: str = "", **metadata) -> None:
        arr = np.asarray(data)
        self.items[name] = TraceItem(name, arr, str(arr.dtype), tuple(arr.shape), sample_rate, frequency,
                                     time.time(), source, metadata)

    def get(self, name: str, default=None):
        it = self.items.get(name)
        return default if it is None else it.data

    def __contains__(self, name: str) -> bool:
        return name in self.items

    def names(self):
        return sorted(self.items)

    def save(self, directory: str | Path) -> None:
        d = Path(directory)
        d.mkdir(parents=True, exist_ok=True)
        index = {}
        for name, it in self.items.items():
            np.save(d / f"{name}.npy", it.data)
            index[name] = {"dtype": it.dtype, "shape": list(it.shape), "sample_rate": it.sample_rate,
                           "frequency": it.frequency, "timestamp": it.timestamp, "source": it.source,
                           "metadata": _jsonable(it.metadata), "file": f"{name}.npy"}
        with open(d / "trace.json", "w", encoding="utf-8") as f:
            json.dump(index, f, indent=2)

    @staticmethod
    def load(directory: str | Path) -> "Trace":
        d = Path(directory)
        t = Trace()
        with open(d / "trace.json", "r", encoding="utf-8") as f:
            index = json.load(f)
        for name, m in index.items():
            t.items[name] = TraceItem(name, np.load(d / m["file"], allow_pickle=False), m["dtype"], tuple(m["shape"]),
                                      m["sample_rate"], m["frequency"], m["timestamp"], m["source"], m["metadata"])
        return t


def _jsonable(o: Any):
    if isinstance(o, dict):
        return {str(k): _jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_jsonable(v) for v in o]
    if isinstance(o, np.ndarray):
        return o.tolist()
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.complexfloating, complex)):
        return [float(np.real(o)), float(np.imag(o))]
    return o


jsonable = _jsonable
