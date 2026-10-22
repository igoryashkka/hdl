"""Reassembles a file sent with `plutolink tx --file` from an IQ capture of the second board.

Every packet carries the plutolink header ([12] chunk index in step_id, [24] file size in prbs_seed) and a chunk of the file;
only packets whose payload CRC32 is good are used. The file is complete when every chunk was received at least once.
usage: python experiments/image_rx.py capture.iq --mode 0 --nsyms 4 [--gain-sh 4] [--ref original.png] [--out received.png]
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_capture import check_payload, u32  # noqa: E402
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--mode", type=int, default=0)
    ap.add_argument("--nsyms", type=int, default=4)
    ap.add_argument("--gain-sh", type=int, default=4)
    ap.add_argument("--ref", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    raw = np.fromfile(a.capture, dtype=np.int16)
    iq = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    print(f"capture: {iq.size} samples ({iq.size / 30.72e6 * 1e3:.1f} ms)")
    cfg = build_config({"payload": {"nsyms": a.nsyms}, "phy": {"mode": "max_range" if a.mode == 0 else "max_rate"}, "rx": {"gain_sh": a.gain_sh}})
    cfg["channel"]["adc"]["enabled"] = False
    r = run_experiment(cfg, outdir=None, plots=False, rx_iq_override=iq, truth_override={"delay_samples": 0.0, "cfo_hz": 0.0})
    pk = r.rx_debug.get("packets", [])

    chunks, fsize, n_ok, n_bad = {}, None, 0, 0
    for p in pk:
        b = bytes(p["bytes"])
        c = check_payload(b)
        if not c["crc"]:
            n_bad += 1
            continue
        n_ok += 1
        idx = int.from_bytes(b[12:14], "little")
        fsize = u32(b, 24)
        chunks.setdefault(idx, b[32:-4])
    print(f"packets: {len(pk)} decoded, {n_ok} with good CRC, {n_bad} rejected")
    if fsize is None:
        print("no good packet, nothing to reassemble")
        return 1
    csize = len(next(iter(chunks.values())))
    need = (fsize + csize - 1) // csize
    missing = [k for k in range(need) if k not in chunks]
    print(f"file: {fsize} bytes in {need} chunks of {csize} bytes; received {len(chunks)} distinct chunks" + (f", missing {missing}" if missing else ""))
    data = b"".join(chunks.get(k, bytes(csize)) for k in range(need))[:fsize]
    out = Path(a.out or Path(a.capture).with_suffix(".received.bin"))
    out.write_bytes(data)
    print("written", out, "md5", hashlib.md5(data).hexdigest())
    if a.ref:
        ref = Path(a.ref).read_bytes()
        same = ref == data
        diff = sum(x != y for x, y in zip(ref, data)) + abs(len(ref) - len(data))
        print(f"reference {a.ref}: md5 {hashlib.md5(ref).hexdigest()} -> {'IDENTICAL' if same else f'DIFFERENT ({diff} bytes differ)'}")
        return 0 if same else 2
    return 0 if not missing else 2


if __name__ == "__main__":
    sys.exit(main())
