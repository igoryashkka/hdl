"""Experiment persistence (TZ section 28 layout), replay capture and the HTML report."""
from __future__ import annotations

import base64
import hashlib
import html
import json
from pathlib import Path

import numpy as np
import yaml

from ..core.results import save_metrics
from ..core.trace import jsonable


def _to_int16_iq(iq: np.ndarray) -> np.ndarray:
    a = np.empty(2 * len(iq), np.int16)
    a[0::2] = np.clip(np.round(np.real(iq)), -32768, 32767)
    a[1::2] = np.clip(np.round(np.imag(iq)), -32768, 32767)
    return a


def save_experiment(res, plots: bool = True, html: bool = True) -> None:
    out = res.outdir
    out.mkdir(parents=True, exist_ok=True)
    cfg_clean = json.loads(json.dumps(res.cfg, default=jsonable))
    with open(out / "config.yaml", "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg_clean, f, sort_keys=False)
    (out / "payload.bin").write_bytes(b"".join(res.payload_tx))
    for d in ("tx", "channel", "rx"):
        (out / d).mkdir(exist_ok=True)
    np.save(out / "tx" / "iq.npy", res._iq_tx)
    np.save(out / "channel" / "iq.npy", res._iq_ch)
    np.save(out / "rx" / "iq.npy", res._iq_ch)
    dbg = res.rx_debug
    pk0 = (dbg.get("packets") or [None])[0]
    if pk0 is not None:
        if "fft_data" in pk0:
            np.save(out / "rx" / "fft.npy", np.asarray(pk0["fft_data"]))
        if "H_est" in pk0:
            np.save(out / "rx" / "channel.npy", np.asarray(pk0["H_est"]))
    sm = dbg.get("sync_metric") or {}
    if sm:
        np.save(out / "rx" / "sync.npy", np.asarray(sm["M"]))
    with open(out / "rx" / "events.json", "w", encoding="utf-8") as f:
        json.dump(jsonable(dbg.get("events", [])), f, indent=2)
    res.trace.save(out / "trace")

    # replayable capture (TZ section 11): raw int16 IQ + metadata
    cap = out / "capture"
    cap.mkdir(exist_ok=True)
    _to_int16_iq(res._iq_ch).tofile(cap / "rx.iq")
    _to_int16_iq(res._iq_tx).tofile(cap / "tx.iq")
    _to_int16_iq(res._iq_ch).tofile(cap / "channel.iq")
    (cap / "payload.bin").write_bytes(b"".join(res.payload_tx))
    meta = {"format": "int16 interleaved IQ", "sample_rate": 30.72e6, "config": cfg_clean,
            "ground_truth": {"packet_start": res.truth["packet_start"], "lts_start": res.truth["lts_start"],
                             "cfo_hz": res.truth["cfo_hz"], "timing_offset": res.truth["timing_offset"],
                             "channel": res.truth["channel"]},
            "payload_sha256": hashlib.sha256(b"".join(res.payload_tx)).hexdigest(), "packet_bytes": [len(p) for p in res.payload_tx]}
    with open(cap / "metadata.json", "w", encoding="utf-8") as f:
        json.dump(jsonable(meta), f, indent=2)

    save_metrics(out / "metrics.json", {k: v for k, v in res.metrics.items()})
    files = {}
    if plots:
        from .plots import make_plots
        files = make_plots(res, out / "plots")
    if html:
        write_html(res, out / "report.html", files)


def _fmt(v) -> str:
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:.4g}"
    return html.escape(str(v))


def write_html(res, path: Path, plot_files: dict) -> None:
    m = res.metrics
    rows = [("TX backend", m.get("tx_backend")), ("RX backend", f"{m.get('rx_backend')} {m.get('rx_mode') or ''}"),
            ("SNR [dB]", m.get("snr_db")), ("CFO injected [Hz]", m.get("cfo_hz_injected")),
            ("Timing offset [samples]", m.get("timing_offset_injected")),
            ("Channel", json.dumps({k: v for k, v in res.truth.get("channel", {}).items() if k in
                                    ("multipath", "fading", "iq_imbalance", "phase_noise_cfg", "pa", "interference", "sfo_ppm")},
                                   default=jsonable)),
            ("Packets TX / RX / corrupted / lost", f"{m.get('packets_transmitted')} / {m.get('packets_received')} / "
                                                  f"{m.get('packets_corrupted')} / {m.get('packets_lost')}"),
            ("BER", m.get("ber")), ("SER", m.get("ser")), ("PER", m.get("per")),
            ("EVM rms [%]", m.get("evm_rms_pct")), ("EVM peak [%]", m.get("evm_peak_pct")), ("MER [dB]", m.get("mer_db")),
            ("PAPR [dB]", m.get("papr_db")), ("Crest factor [dB]", m.get("crest_factor_db")),
            ("Occupied BW (99%) [MHz]", None if m.get("occupied_bw_hz") is None else m["occupied_bw_hz"] / 1e6),
            ("CFO estimation error max [Hz]", m.get("cfo_error_abs_max_hz")),
            ("Timing estimation error max [samples]", m.get("timing_error_abs_max")),
            ("Channel estimation MSE [dB]", m.get("channel_est_mse_db")),
            ("ICI / null-bin level [dB]", m.get("ici_null_bin_db")),
            ("CPE std [rad]", m.get("cpe_rad_std")), ("Subcarrier SNR mean [dB]", m.get("subcarrier_snr_db_mean"))]
    perf = m.get("rtl_performance") or {}
    for k, v in perf.items():
        rows.append((f"RTL {k}", v))
    status = "PASS" if res.passed else "FAIL"
    color = "#1a7f37" if res.passed else "#cf222e"
    parts = [f"<html><head><meta charset='utf-8'><title>{html.escape(res.cfg['experiment']['name'])}</title>",
             "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;max-width:1100px}table{border-collapse:collapse}"
             "td,th{border:1px solid #ccc;padding:4px 10px;text-align:left}img{max-width:100%;margin:8px 0}"
             ".s{font-size:28px;font-weight:bold}</style></head><body>",
             f"<h1>{html.escape(res.cfg['experiment']['name'])}</h1>",
             f"<div class='s' style='color:{color}'>{status}</div>"]
    if res.criteria_lines:
        parts.append("<pre>" + html.escape("\n".join(res.criteria_lines)) + "</pre>")
    parts.append("<h2>Metrics</h2><table>")
    parts += [f"<tr><th>{html.escape(str(k))}</th><td>{_fmt(v)}</td></tr>" for k, v in rows]
    parts.append("</table>")
    if m.get("comparison"):
        parts.append("<h2>Backend comparison</h2><pre>" + html.escape(json.dumps(jsonable(m["comparison"]), indent=1)) + "</pre>")
    parts.append("<h2>Plots</h2>")
    for name, p in plot_files.items():
        if p and Path(p).exists():
            b64 = base64.b64encode(Path(p).read_bytes()).decode()
            parts.append(f"<h3>{html.escape(name)}</h3><img src='data:image/png;base64,{b64}'/>")
    parts.append("</body></html>")
    path.write_text("".join(parts), encoding="utf-8")
