"""Experiment runner: the 14-step workflow of TZ section 26, independent of where the PHY runs."""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import yaml

from .. import refs
from ..analysis import statistics as st
from ..analysis import synchronization as syn
from ..analysis import channel as ach
from ..analysis import performance
from ..channel.chain import Channel
from ..comparison import rtl_vs_python
from ..phy import golden
from .backend import make_rx, make_tx
from .results import evaluate_criteria, save_metrics
from .trace import Trace, jsonable


@dataclass
class ExperimentResult:
    cfg: dict
    metrics: dict
    passed: bool
    criteria_lines: list
    trace: Trace
    truth: dict
    outdir: Path | None = None
    payload_tx: list = field(default_factory=list)
    payload_rx: list = field(default_factory=list)
    rx_debug: dict = field(default_factory=dict)
    tx_debug: dict = field(default_factory=dict)


# ------------------------------------------------------------------ helpers
def make_payloads(cfg: dict, rng: np.random.Generator) -> list[bytes]:
    n = int(cfg["payload"]["nsyms"]) * refs.bytes_per_sym(cfg)
    pat = cfg["payload"].get("pattern", "random")
    out = []
    for k in range(int(cfg["experiment"].get("n_packets", 1))):
        if pat == "random":
            b = rng.integers(0, 256, n, dtype=np.uint8).tobytes()
        elif pat == "zeros":
            b = bytes(n)
        elif pat == "ones":
            b = bytes([255]) * n
        elif pat == "counter":
            b = bytes((i + k) & 255 for i in range(n))
        else:
            raise ValueError(f"unknown payload pattern '{pat}'")
        out.append(b)
    return out


def _backend_name(spec: str) -> tuple[str, dict]:
    """'python' | 'rtl' | 'python:float' -> (backend, overrides)"""
    if ":" in spec:
        name, mode = spec.split(":", 1)
        return name, {"mode": mode}
    return spec, {}


def _rx_backend_cfg(cfg: dict, spec: str) -> tuple:
    name, over = _backend_name(spec)
    c = json.loads(json.dumps(cfg, default=jsonable))
    c["rx"].update(over)
    return name, c


# ------------------------------------------------------------------ main
def run_experiment(cfg: dict, outdir: str | Path | None = None, plots: bool | None = None, quiet: bool = True,
                   rx_iq_override: np.ndarray | None = None, truth_override: dict | None = None) -> ExperimentResult:
    t0 = time.time()
    seed = int(cfg["experiment"].get("seed", 1))
    rng = np.random.default_rng(seed)
    trace = Trace()
    exp = cfg["experiment"]

    # 1-3: payload, TX configure/send
    payloads = make_payloads(cfg, rng)
    nsyms = int(cfg["payload"]["nsyms"])
    tx = make_tx(cfg["tx"]["backend"])
    tx.configure(cfg)
    tx.reset()
    tx.send(payloads)
    # 4-5: TX IQ
    iq_tx = tx.get_iq()
    tx_dbg = tx.get_debug()
    trace.record("tx_iq", iq_tx, sample_rate=refs.FS, source=f"tx:{cfg['tx']['backend']}")

    lead, trail = int(exp.get("lead_samples", 1200)), int(exp.get("trail_samples", 3000))
    stream = np.concatenate([np.zeros(lead, complex), iq_tx, np.zeros(trail, complex)])
    starts_tx = [lead + s for s in tx_dbg.get("packet_starts", [0])]

    # 6: channel
    ch = Channel(cfg["channel"])
    if rx_iq_override is None:
        iq_ch, truth = ch.process(stream, rng)
    else:                                                   # replay: the channel is not simulated again
        iq_ch, truth = np.asarray(rx_iq_override), dict(truth_override or {})
    trace.record("channel_iq", iq_ch, sample_rate=refs.FS, source="channel")
    delay = float(truth.get("delay_samples", 0.0))
    starts_rx = [s + delay for s in starts_tx]
    layout = golden.frame_layout(nsyms)
    gt = {"packet_start": starts_rx, "lts_start": [s + layout["lts_start"] for s in starts_rx],
          "data_symbol_starts": [[s + d for d in layout["data_starts"]] for s in starts_rx],
          "cfo_hz": float(cfg["channel"].get("cfo_hz", 0.0)) if rx_iq_override is None else truth.get("cfo_hz", 0.0),
          "timing_offset": delay, "channel": {k: v for k, v in truth.items() if k not in ("fs",)},
          "tx_bits": [golden.tx_bits(p) for p in payloads]}
    gt["tx_symbols"] = [golden.tx_data_symbols(p, refs.phy_code(cfg))[0] for p in payloads]

    # 7-9: RX
    rx = make_rx(cfg["rx"]["backend"])
    rx.configure(cfg)
    rx.reset()
    rx.process(iq_ch)
    payload_rx = rx.get_payload()
    rx_dbg = rx.get_debug()
    if rx_dbg.get("sync_metric"):
        trace.record("sync_metric", rx_dbg["sync_metric"]["M"], source="rx", kind="Schmidl-Cox M(n)")

    # 10-11: metrics
    metrics = compute_metrics(cfg, payloads, payload_rx, tx_dbg, rx_dbg, iq_tx, iq_ch, ch, gt, truth, trace)

    # optional backend cross-check (e.g. rx.compare_with: [python:fixed])
    for spec in cfg["rx"].get("compare_with", []) or []:
        name, c2 = _rx_backend_cfg(cfg, spec)
        other = make_rx(name)
        other.configure(c2)
        other.reset()
        other.process(iq_ch)
        metrics.setdefault("comparison", {})[spec] = rtl_vs_python.compare_rx(other.get_payload(), other.get_debug(), payload_rx, rx_dbg)

    passed, lines = evaluate_criteria(metrics, cfg.get("criteria", {}))
    metrics["passed"] = bool(passed)
    metrics["runtime_s"] = time.time() - t0
    res = ExperimentResult(cfg, metrics, passed, lines, trace, gt, None, payloads, payload_rx, rx_dbg, tx_dbg)
    res._iq_tx, res._iq_ch, res._channel, res._stream = iq_tx, iq_ch, ch, stream     # for plotting / saving

    # 12-14: plots, report, save
    if outdir is not None:
        from ..report.report import save_experiment
        res.outdir = Path(outdir)
        save_experiment(res, plots=cfg["report"].get("plots", True) if plots is None else plots,
                        html=cfg["report"].get("html", True))
    return res


def compute_metrics(cfg, payloads, payload_rx, tx_dbg, rx_dbg, iq_tx, iq_ch, ch, gt, truth, trace) -> dict:
    m: dict = {"tx_backend": cfg["tx"]["backend"], "rx_backend": cfg["rx"]["backend"],
               "rx_mode": cfg["rx"].get("mode") if cfg["rx"]["backend"] == "python" else None,
               "snr_db": cfg["channel"].get("snr_db"), "cfo_hz_injected": gt["cfo_hz"], "timing_offset_injected": gt["timing_offset"]}
    n_tx = len(payloads)
    events = [e for e in rx_dbg.get("events", [])]
    ok_events = [e for e in events if e.get("status", "ok") == "ok"]
    # associate decoded packets with the transmitted ones through the detection time
    assoc: list[tuple[int, int]] = []                   # (rx index, tx index)
    used = set()
    for r_i, e in enumerate(ok_events):
        if r_i >= len(payload_rx):
            break
        d = [abs(e["sync_start_est"] - s) for s in gt["packet_start"]]
        k = int(np.argmin(d))
        if d[k] < 3000 and k not in used:
            used.add(k)
            assoc.append((r_i, k))
    if not ok_events and payload_rx:                    # backends without events: associate by order
        assoc = [(i, i) for i in range(min(len(payload_rx), n_tx))]
        used = {k for _, k in assoc}
    m["packets_transmitted"] = n_tx
    m["packets_received"] = len(assoc)
    m["false_detections"] = max(0, len(payload_rx) - len(assoc))
    corrupted = 0
    be = bt = se = sn = 0
    for r_i, k in assoc:
        e1, t1 = st.bit_errors(payloads[k], payload_rx[r_i])
        e2, t2 = st.symbol_errors(payloads[k], payload_rx[r_i])
        corrupted += int(e1 > 0)
        be, bt, se, sn = be + e1, bt + t1, se + e2, sn + t2
    lost = n_tx - len(assoc)
    m["packets_corrupted"] = corrupted
    m["packets_lost"] = lost
    m["per"] = (corrupted + lost) / n_tx
    m["bits_transmitted"] = int(sum(len(p) * 8 for p in payloads))
    m["bit_errors"], m["symbol_errors"] = int(be), int(se)
    m["ber"] = be / bt if bt else 0.5
    m["ser"] = se / sn if sn else 15 / 16
    lost_bits = sum(len(payloads[k]) * 8 for k in range(n_tx) if k not in used)
    m["ber_incl_lost"] = (be + 0.5 * lost_bits) / m["bits_transmitted"]

    # constellation quality
    eqs, refs_, sc_snr = [], [], []
    for r_i, k in assoc:
        pk = (rx_dbg.get("packets") or [None] * (r_i + 1))[r_i] if rx_dbg.get("packets") else None
        if pk is not None and "eq" in pk and np.size(pk["eq"]):
            eq = np.asarray(pk["eq"])
            ref = gt["tx_symbols"][k]
            if eq.shape == ref.shape:
                eqs.append(eq); refs_.append(ref)
    if eqs:
        eq_all, ref_all = np.concatenate(eqs), np.concatenate(refs_)
        m.update(st.evm(eq_all, ref_all))
        m["subcarrier_snr_db_mean"] = float(np.mean(st.subcarrier_snr_db(eq_all, ref_all)))
        trace.record("equalized", eq_all, source="rx")
        gt["_eq_all"], gt["_ref_all"] = eq_all, ref_all
    # waveform metrics (TX side)
    if iq_tx.size and np.any(iq_tx):
        m["papr_db"] = st.papr_db(iq_tx)
        m["crest_factor_db"] = st.crest_factor_db(iq_tx)
        m["occupied_bw_hz"] = st.occupied_bandwidth_hz(iq_tx)
    angs = [np.asarray(p.get("angles", [])) for p in (rx_dbg.get("packets") or [])]
    if angs and angs[0].size:
        m.update(st.cpe_stats(np.concatenate(angs)))
    # synchronisation
    if events or gt["packet_start"]:
        s_rep = syn.sync_report(ok_events, gt["packet_start"], gt["cfo_hz"])
        m["sync"] = s_rep
        m["sync_failures"] = s_rep["missed"] + s_rep["false_alarms"]
        for kk in ("timing_error_abs_max", "cfo_error_abs_max_hz"):
            if kk in s_rep:
                m[kk] = s_rep[kk]
        if s_rep["matches"]:
            m["timing_error_mean"] = float(np.mean([x["timing_error"] for x in s_rep["matches"]]))
            m["cfo_error_mean_hz"] = float(np.mean([x["cfo_error_hz"] for x in s_rep["matches"]]))
    # channel estimation
    mses = []
    for r_i, k in assoc:
        pk = (rx_dbg.get("packets") or [])[r_i] if r_i < len(rx_dbg.get("packets") or []) else None
        if pk is not None and "H_est" in pk and len(pk["H_est"]) == refs.P.NUM_ACTIVE_SC:
            lts_idx = int(gt["lts_start"][k] - delay_of(truth) + refs.P.CP_LEN)
            h_true = ch.frequency_response(refs.rx_ref.ACTIVE_BINS, at_index=lts_idx)
            e = ach.estimation_error(pk["H_est"], h_true)
            mses.append(e["mse_db"])
            gt.setdefault("_h", []).append((np.asarray(pk["H_est"]), e["h_true_fit"], e))
    if mses:
        m["channel_est_mse_db"] = float(10 * np.log10(np.mean(10 ** (np.asarray(mses) / 10))))
        m["channel_est_error_db_per_packet"] = [float(v) for v in mses]
    # LDPC / channel-quality statistics of the new PHY
    pkts = rx_dbg.get("packets") or []
    its_all = [i for p_ in pkts for i in p_.get("ldpc_iterations", [])]
    if its_all:
        ncw = sum(p_.get("ldpc_codewords", 0) for p_ in pkts)
        nfail = sum(p_.get("ldpc_failures", 0) for p_ in pkts)
        m["ldpc_iterations_mean"] = float(np.mean(its_all))
        m["ldpc_iterations_max"] = int(max(its_all))
        m["ldpc_decoding_failures"] = int(nfail)
        m["fer"] = nfail / ncw if ncw else 0.0                       # frame = LDPC codeword
    qs = [p_ for p_ in pkts if "snr_avg_db" in p_]
    if qs:
        m["channel_snr_db_mean"] = float(np.mean([p_["snr_avg_db"] for p_ in qs]))
        m["snr_min_db_mean"] = float(np.mean([p_["snr_min_db"] for p_ in qs]))
        m["bad_subcarriers_mean"] = float(np.mean([p_["bad_subcarriers"] for p_ in qs]))
    # fine timing / residual CFO / SFO estimation errors of the new PHY (estimate vs the injected ground truth)
    tau_errs, sfo_errs, cfo_res = [], [], []
    for r_i, k in assoc:
        if r_i < len(ok_events) and "tau_est" in ok_events[r_i]:
            tau_true = gt["lts_start"][k] + refs.P.CP_LEN - ok_events[r_i]["w0"]
            tau_errs.append(ok_events[r_i]["tau_est"] - tau_true)
        pk = pkts[r_i] if r_i < len(pkts) else None
        if pk is not None and pk.get("sfo_slopes"):
            sl = pk["sfo_slopes"][-1] / 2 ** 32 * 2 * np.pi                       # rad per bin at the last data symbol
            n_last = len(pk["sfo_slopes"])
            ppm_est = sl * 2048 / (2 * np.pi) / (n_last * refs.SYM_LEN) * 1e6      # window drift relative to the LTS = n * SYM_LEN * ppm
            sfo_errs.append(abs(ppm_est) - abs(float(cfg["channel"].get("sfo_ppm", 0.0))))
            sfo_errs[-1] = abs(abs(ppm_est) - abs(float(cfg["channel"].get("sfo_ppm", 0.0))))
            a = pk.get("angles_raw") or []
            if len(a) > 1:
                d = [((a[i + 1] - a[i] + 2 ** 31) % 2 ** 32 - 2 ** 31) for i in range(len(a) - 1)]
                cfo_res.append(np.mean(d) / 2 ** 32 * refs.FS / refs.SYM_LEN)       # Hz: dtheta per symbol / (2 pi T_sym)
    if tau_errs:
        m["fine_timing_error_abs_max"] = float(np.max(np.abs(tau_errs)))
        m["fine_timing_error_mean"] = float(np.mean(tau_errs))
    if sfo_errs:
        m["sfo_estimation_error_ppm"] = float(np.max(sfo_errs))
    if cfo_res:
        m["cfo_residual_estimate_hz_mean"] = float(np.mean(cfo_res))
        m["cfo_residual_estimate_hz_absmax"] = float(np.max(np.abs(cfo_res)))
    # ICI / leakage proxy
    bodies = [int(round(s)) + refs.P.CP_LEN for sl in gt["data_symbol_starts"][:1] for s in sl]
    m["ici_null_bin_db"] = st.null_bin_ratio_db(iq_ch, bodies)
    # RTL performance
    perf = {}
    perf.update(rx_dbg.get("perf", {}))
    perf.update(tx_dbg.get("perf", {}))
    if perf:
        m["rtl_performance"] = performance.rtl_performance(perf, bytes_per_sym=refs.bytes_per_sym(cfg))
    if truth.get("adc"):
        m["adc"] = truth["adc"]
    return m


def delay_of(truth: dict) -> float:
    return float(truth.get("delay_samples", 0.0))
