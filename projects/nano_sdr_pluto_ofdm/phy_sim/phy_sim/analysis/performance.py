"""RTL performance metrics (TZ section 17) from the simulation log + optional Vivado reports."""
from __future__ import annotations

import re
from pathlib import Path

from .. import refs


def rtl_performance(log: dict, clk_hz: float = 2 * refs.FS, bytes_per_sym: int | None = None) -> dict:
    """log: numbers emitted by the RTL testbench (cycles, samples, beats). Returns latency / throughput figures."""
    bps = bytes_per_sym or refs.BYTES_PER_SYM
    out = {}
    clk_per_sample = float(log.get("clks_per_sample", 2))
    if "rx_first_beat_clk" in log and "rx_last_sample_clk" in log:
        out["rx_packet_latency_clks"] = int(log["rx_first_beat_clk"] - log["rx_last_sample_clk"])
        out["rx_packet_latency_us"] = out["rx_packet_latency_clks"] / clk_hz * 1e6
        out["rx_packet_latency_samples"] = out["rx_packet_latency_clks"] / clk_per_sample
    if "tx_first_iq_clk" in log and "tx_last_byte_clk" in log:
        out["tx_packet_latency_clks"] = int(log["tx_first_iq_clk"] - log["tx_last_byte_clk"])
        out["tx_packet_latency_us"] = out["tx_packet_latency_clks"] / clk_hz * 1e6
    if "tx_samples" in log and "tx_payload_bytes" in log and log["tx_samples"]:
        air_time_s = log["tx_samples"] / refs.FS
        out["tx_payload_throughput_mbps"] = log["tx_payload_bytes"] * 8 / air_time_s / 1e6
    if "tx_first_packet_bytes" in log and log["tx_first_packet_bytes"]:
        nsym = -(-log["tx_first_packet_bytes"] // bps)
        out["phy_payload_rate_mbps_this_packet_size"] = nsym * bps * 8 / ((nsym + 2) * refs.SYM_LEN / refs.FS) / 1e6
        out["phy_payload_rate_mbps_8_symbols"] = 8 * bps * 8 / (10 * refs.SYM_LEN / refs.FS) / 1e6
    for k in ("stall_cycles", "underflow", "overflow", "sim_clks", "tx_gap_samples", "rx_beats", "rx_drops"):
        if k in log:
            out[k] = log[k]
    return out


def parse_vivado_reports(project_dir: str | Path) -> dict:
    """Best-effort extraction of LUT/FF/BRAM/DSP and WNS/TNS/WHS/THS from reports left by build_vivado.bat."""
    d = Path(project_dir)
    out = {}
    util = d / "reports_util.rpt"
    if util.exists():
        t = util.read_text(errors="ignore")
        for key, pat in (("lut", r"\| Slice LUTs\*?\s*\|\s*(\d+)"), ("ff", r"\| Slice Registers\s*\|\s*(\d+)"),
                         ("bram", r"\| Block RAM Tile\s*\|\s*([\d.]+)"), ("dsp", r"\| DSPs\s*\|\s*(\d+)")):
            m = re.search(pat, t)
            if m:
                out[key] = float(m.group(1))
    log = d / "build.log"
    if log.exists():
        m = None
        for m in re.finditer(r"Route 35-57\] Estimated Timing Summary \| WNS=([-\d.]+)\s*\| TNS=([-\d.]+)\s*\| WHS=([-\d.]+)\s*\| THS=([-\d.]+)",
                             log.read_text(errors="ignore")):
            pass
        if m:
            out.update(wns=float(m.group(1)), tns=float(m.group(2)), whs=float(m.group(3)), ths=float(m.group(4)))
    return out
