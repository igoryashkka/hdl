"""Collects the Vivado results of the Z7020 builds (nano_sdr_pluto_ofdm_{rx,tx}) into results/compare/resources.json:
totals (LUT / FF / BRAM / DSP / slices), timing (WNS / TNS / WHS / THS, Fmax at the 8 ns constraint) and the hierarchical PHY breakdown."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]            # .../nano_sdr_pluto_ofdm
PROJ = ROOT.parent


def parse_util(path: Path) -> dict:
    t = path.read_text(errors="ignore")
    out = {}
    for key, pat in (("lut", r"\| Slice LUTs\*?\s*\|\s*(\d+)"), ("lut_total", r"\| Slice LUTs\*?\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)"),
                     ("ff", r"\| Slice Registers\s*\|\s*(\d+)"), ("bram", r"\| Block RAM Tile\s*\|\s*([\d.]+)"),
                     ("dsp", r"\| DSPs\s*\|\s*(\d+)"), ("slice", r"\| Slice\s*\|\s*(\d+)"), ("lutram", r"\| LUT as Memory\s*\|\s*(\d+)")):
        m = re.search(pat, t)
        if m:
            out[key] = float(m.group(1))
    return out


def parse_timing(proj: Path) -> dict:
    t = (proj / "reports_timing.rpt").read_text(errors="ignore") if (proj / "reports_timing.rpt").exists() else ""
    m = re.search(r"WNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+\d+\s+\d+\s+(-?[\d.]+)\s+(-?[\d.]+)", t, re.S)
    out = {}
    if m:
        out = {"wns": float(m.group(1)), "tns": float(m.group(2)), "whs": float(m.group(3)), "ths": float(m.group(4))}
        out["fmax_mhz"] = 1000.0 / (8.0 - out["wns"])
    return out


def parse_hier(path: Path) -> list:
    rows = []
    for line in path.read_text(errors="ignore").splitlines():
        if not line.startswith("|") or "Instance" in line or "---" in line:
            continue
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) < 10:
            continue
        try:
            rows.append({"inst": c[0], "module": c[1], "lut": int(c[2]), "lutram": int(c[4]), "ff": int(c[6]), "bram36": int(c[7]), "bram18": int(c[8]), "dsp": int(c[9]),
                         "depth": len(line) - len(line.lstrip("| ")) })
        except ValueError:
            continue
    return rows


def main():
    res = {}
    for v in ("rx", "tx"):
        p = PROJ / f"nano_sdr_pluto_ofdm_{v}"
        d = {"util": parse_util(p / "reports_util.rpt") if (p / "reports_util.rpt").exists() else {}, "timing": parse_timing(p)}
        h = p / "reports_util_hier.rpt"
        if h.exists():
            rows = parse_hier(h)
            keep = [r for r in rows if r["inst"] in ("phy_rx", "phy_tx", "u_phy", "u_dec", "u_ldpc", "u_dm", "u_deint", "u_nse", "u_post", "u_chest", "u_eq", "u_trk", "u_fft",
                                                    "u_sync", "u_pkt", "u_enc", "u_regs", "u_cfo", "u_mix", "u_win", "u_rssi", "u_tau", "u_il", "u_ifft", "u_cp", "u_bsel",
                                                    "u_desc", "axi_ad9361", "pkt_dma", "axi_ad9361_dac_dma", "u_qam", "u_ctrl", "u_scr")]
            d["hier"] = [{k: r[k] for k in ("inst", "module", "lut", "ff", "bram36", "bram18", "dsp", "lutram")} for r in keep]
        res[v] = d
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "phy_sim" / "results" / "compare" / "resources.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(res, indent=1))
    print(json.dumps({k: {"util": v["util"], "timing": v["timing"]} for k, v in res.items()}, indent=1))


if __name__ == "__main__":
    main()
