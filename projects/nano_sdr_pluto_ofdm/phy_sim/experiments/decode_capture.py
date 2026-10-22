"""Decodes an IQ capture of the hardware OFDM transmitter (plutolink tx) with the bit-exact Python receiver models.

Input : int16 interleaved I/Q at 30.72 MS/s (e.g. iio_readdev ... cf-ad9361-lpc voltage0 voltage1 on a second board).
Output: per detected packet the header (MODE_ID), LDPC result, channel SNR and CFO, and whether the plutolink payload is intact
        (magic 'PLNK', header CRC32, payload CRC32); a summary line; results/hw/<name>.json.
usage : python experiments/decode_capture.py cap.iq --mode 0 --nsyms 2 [--gain-sh N]
"""
from __future__ import annotations

import argparse
import json
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.core.experiment import run_experiment  # noqa: E402

MAGIC = 0x4B4E4C50          # 'PLNK', little endian (sw/plutolink/plutolink.c)


def u32(b, o):
    return int.from_bytes(b[o:o + 4], "little")


def check_payload(b: bytes) -> dict:
    """plutolink application payload: [0] magic, [4] seq, [28] crc32(0..27), [n-4] crc32(0..n-5)."""
    if len(b) < 36:
        return {"magic": False, "hdr_crc": False, "crc": False, "seq": None}
    hdr_ok = u32(b, 0) == MAGIC and u32(b, 28) == zlib.crc32(b[:28])
    return {"magic": u32(b, 0) == MAGIC, "hdr_crc": hdr_ok, "crc": u32(b, len(b) - 4) == zlib.crc32(b[:-4]),
            "seq": u32(b, 4) if hdr_ok else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--mode", type=int, default=0, help="0 = MAX RANGE, 1 = MAX RATE (fallback when the header symbol fails)")
    ap.add_argument("--nsyms", type=int, default=2)
    ap.add_argument("--gain-sh", type=int, default=0, help="digital shift in front of the detector (signed, like the RTL)")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    raw = np.fromfile(a.capture, dtype=np.int16)
    iq = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    rms = float(np.sqrt(np.mean(np.abs(iq) ** 2))) if iq.size else 0.0
    peak = int(np.max(np.abs(raw))) if raw.size else 0
    print(f"capture: {iq.size} samples ({iq.size / 30.72e6 * 1e3:.1f} ms), rms {rms:.0f}, peak {peak} (ADC full scale 2048)")

    cfg = build_config({"payload": {"nsyms": a.nsyms}, "phy": {"mode": "max_range" if a.mode == 0 else "max_rate"},
                        "rx": {"gain_sh": a.gain_sh}})
    cfg["channel"]["adc"]["enabled"] = False
    r = run_experiment(cfg, outdir=None, plots=False, rx_iq_override=iq, truth_override={"delay_samples": 0.0, "cfo_hz": 0.0})
    ev = r.rx_debug.get("events", [])
    pk = r.rx_debug.get("packets", [])
    rows = []
    for k, p in enumerate(pk):
        c = check_payload(bytes(p["bytes"]))
        e = ev[k] if k < len(ev) else {}
        hdr = p.get("hdr") or {}
        rows.append({"n": k, "sample": e.get("n_best"), "cfo_hz": e.get("cfo_hz_est"), "hdr_ok": bool(hdr.get("ok")), "mode": p.get("mode_used"),
                     "ldpc_failed": p.get("ldpc_failures"), "ldpc_iter": p.get("ldpc_iterations"), "snr_db": p.get("snr_avg_db"),
                     "snr_min_db": p.get("snr_min_db"), **c})
    print(f"{'#':>3} {'sample':>9} {'CFO Hz':>8} {'hdr':>4} {'mode':>4} {'LDPC fail':>9} {'SNR dB':>7} {'magic':>5} {'CRC':>4} {'seq':>7}")
    for x in rows:
        print(f"{x['n']:>3} {x['sample'] if x['sample'] is not None else '-':>9} {x['cfo_hz'] if x['cfo_hz'] is None else round(x['cfo_hz']):>8} "
              f"{'ok' if x['hdr_ok'] else 'BAD':>4} {x['mode']!s:>4} {x['ldpc_failed']!s:>9} {x['snr_db'] if x['snr_db'] is None else round(x['snr_db'], 1):>7} "
              f"{'ok' if x['magic'] else '-':>5} {'ok' if x['crc'] else 'BAD':>4} {x['seq'] if x['seq'] is not None else '-':>7}")
    good = sum(1 for x in rows if x["crc"])
    snrs = [x["snr_db"] for x in rows if x["snr_db"] is not None]
    print(f"\nsummary: {len(ev)} detections, {len(rows)} packets decoded, {good} with intact payload (CRC32 ok)"
          + (f", channel SNR {np.mean(snrs):.1f} dB average" if snrs else ""))
    out = Path(a.out) if a.out else Path("results/hw") / (Path(a.capture).stem + ".json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"capture": str(a.capture), "samples": int(iq.size), "rms": rms, "peak": peak, "packets": rows}, indent=1, default=str))
    print("->", out)


if __name__ == "__main__":
    main()
