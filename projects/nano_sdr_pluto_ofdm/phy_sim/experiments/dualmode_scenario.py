"""RTL scenario of the dual-mode PHY: TX (RTL, xsim) -> per-packet channel -> RX (RTL, xsim) and RX (python:fixed) on the same samples.
A scripted link: the packets change mode and SNR (MAX RATE on a good link, switch to MAX RANGE when the link degrades, MAX RANGE at its limit,
MAX RATE on the weak link for contrast). The RX does not know the mode in advance: it takes MODE_ID from the header symbol of every packet.
Output: results/dualmode/scenario.json with per-packet results (payload ok, mode decoded, header, LDPC iterations / failures, SNR estimate, EVM,
constellation samples of the equalised data symbols, RTL latency), plus the RTL-vs-model comparison.
usage: python experiments/dualmode_scenario.py [--out results/dualmode]"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from phy_sim import refs  # noqa: E402
from phy_sim.channel.chain import Channel  # noqa: E402
from phy_sim.core.backend import make_rx, make_tx  # noqa: E402
from phy_sim.core.config import build_config  # noqa: E402
from phy_sim.phy import golden  # noqa: E402
import phy_sim.phy.python_tx  # noqa: E402,F401  (register backends)
import phy_sim.phy.python_rx  # noqa: E402,F401
import phy_sim.rtl.xsim.tx  # noqa: E402,F401
import phy_sim.rtl.xsim.rx  # noqa: E402,F401

MP = [{"delay": 0, "gain_db": 0}, {"delay": 10, "gain_db": -6}, {"delay": 25, "gain_db": -12}]
SCENARIOS = {
    "awgn_ladder": {
        "title": "AWGN link degrading and recovering (CFO 3 kHz)",
        "channel": {"cfo_hz": 3000},
        "plan": [("A", 1, 30, "MAX RATE, good link"), ("B", 1, 15, "MAX RATE, 15 dB"), ("C", 0, 15, "switch to MAX RANGE, same link"),
                 ("D", 0, 6, "MAX RANGE, 6 dB"), ("E", 0, 1.5, "MAX RANGE near its limit"), ("F", 1, 6, "MAX RATE on the 6 dB link"),
                 ("G", 0, 6, "back to MAX RANGE")],
    },
    "impaired": {
        "title": "3-path channel, CFO 5 kHz, SFO 15 ppm, phase noise 50 Hz",
        "channel": {"multipath": MP, "cfo_hz": 5000, "sfo_ppm": 15, "phase_noise": {"linewidth_hz": 50}},
        "plan": [("A", 1, 24, "MAX RATE, 24 dB"), ("B", 0, 24, "MAX RANGE, 24 dB"), ("C", 0, 8, "MAX RANGE, 8 dB"), ("D", 0, 4, "MAX RANGE, 4 dB"),
                 ("E", 1, 14, "MAX RATE, 14 dB")],
    },
}
NSYMS = 2
GAP = 32000                                                       # samples between the packets (the RX needs the decode time of the previous one)


def run_scenario(sid: str, spec: dict, seed: int = 11) -> dict:
    rng = np.random.default_rng(seed)
    plan = spec["plan"]
    modes = [m for _, m, _, _ in plan]
    cfg = build_config({"experiment": {"n_packets": len(plan), "seed": seed, "packet_gap": GAP, "lead_samples": 1500}, "payload": {"nsyms": NSYMS},
                        "phy": {"mode": "max_rate"}, "tx": {"backend": "rtl"}, "rx": {"backend": "rtl"}, "channel": {}})
    pay = []
    for m in modes:
        pay.append(rng.integers(0, 256, NSYMS * refs.phy2_ref.info_bytes_per_sym(m), dtype=np.uint8).tobytes())
    tx = make_tx("rtl")
    tx.configure(cfg)
    tx.reset()
    tx.send(pay)
    tx.mode_ids = modes
    t0 = time.time()
    iq_tx = tx.get_iq()
    tdbg = tx.get_debug()
    starts, lens = tdbg["packet_starts"], [(NSYMS + 3) * refs.SYM_LEN for _ in plan]
    print(sid, "tx done", round(time.time() - t0), "s", flush=True)
    # per-packet channel
    parts, rx_starts, pos = [np.zeros(1500, complex)], [], 1500
    truths = []
    for k, (name, m, snr, label) in enumerate(plan):
        seg = iq_tx[starts[k]:starts[k] + lens[k]]
        ch = Channel({**spec["channel"], "snr_db": snr, "adc": {"enabled": True, "bits": 12, "rms": 600.0, "clip": True}})
        x, truth = ch.process(np.concatenate([np.zeros(300, complex), seg, np.zeros(300, complex)]), rng)
        rx_starts.append(pos + 300 + int(truth.get("delay_samples", 0)))
        truths.append(truth)
        parts.append(x)
        pos += len(x)
        if k != len(plan) - 1:
            parts.append(np.zeros(GAP, complex))
            pos += GAP
    parts.append(np.zeros(4000, complex))
    stream = np.concatenate(parts)

    out = {"id": sid, "title": spec["title"], "samples": len(stream), "plan": [{"name": n, "mode": m, "snr_db": s, "label": l} for n, m, s, l in plan], "rx": {}}
    for backend in ("python", "rtl"):
        c = build_config({"experiment": {"n_packets": len(plan)}, "payload": {"nsyms": NSYMS}, "phy": {"mode": "max_rate"},
                          "rx": {"backend": backend, "mode": "fixed"}, "channel": {}})
        rx = make_rx(backend)
        rx.configure(c)
        rx.reset()
        t1 = time.time()
        rx.process(stream)
        dbg = rx.get_debug()
        print(sid, backend, "rx done", round(time.time() - t1), "s", flush=True)
        # match detected events with the transmitted packets by position
        res = [None] * len(plan)
        evs = dbg.get("events", [])
        pkts = dbg.get("packets", [])
        pk_i = 0
        for ev in evs:
            if ev.get("status") != "ok" or pk_i >= len(pkts):
                continue
            exp = [abs(ev["n_best"] - (s + refs.SYNC_PEAK_OFFSET)) for s in rx_starts]
            j = int(np.argmin(exp))
            if exp[j] < 3000 and res[j] is None:
                res[j] = (ev, pkts[pk_i])
            pk_i += 1
        out["rx"][backend] = {"perf": dbg.get("perf"), "status": dbg.get("status"), "events": len(evs), "packets": []}
        for j, (name, m, snr, label) in enumerate(plan):
            rec = {"name": name, "mode": m, "snr_db": snr, "label": label, "detected": res[j] is not None}
            if res[j] is not None:
                ev, pk = res[j]
                got = pk["bytes"]
                lay = refs.phy2_ref.layout(m)
                n = len(pay[j])
                rec.update({"payload_ok": bytes(got[:n]) == pay[j], "bytes_rx": len(got), "bytes_tx": n,
                            "byte_errors": int(sum(a != b for a, b in zip(got[:n], pay[j]))) + max(0, n - len(got)),
                            "mode_used": pk.get("mode_used"), "hdr_ok": (pk.get("hdr") or {}).get("ok"),
                            "ldpc_failures": pk.get("ldpc_failures"), "ldpc_iterations": pk.get("ldpc_iterations"),
                            "snr_est_db": pk.get("snr_avg_db"), "snr_min_db": pk.get("snr_min_db"), "bad_sc": pk.get("bad_subcarriers"),
                            "tau": pk.get("tau_q8", 0) / 256.0 if pk.get("tau_q8") is not None else None, "cfo_hz_est": ev.get("cfo_hz_est"),
                            "n_best": ev["n_best"]})
                eq = np.asarray(pk.get("eq", []))
                ideal = golden.tx_data_symbols(pay[j], "ldpc", m)[0]
                if eq.size == ideal.size:
                    d = eq.ravel() - ideal.ravel()
                    p = float(np.mean(np.abs(ideal) ** 2))
                    rec["evm_pct"] = float(np.sqrt(np.mean(np.abs(d) ** 2) / p) * 100)
                    sel = rng.choice(eq.size, size=min(500, eq.size), replace=False)
                    rec["scatter"] = [[round(float(eq.ravel()[i].real) / 4096, 3), round(float(eq.ravel()[i].imag) / 4096, 3)] for i in sel]
                    rec["ideal_units"] = [round(float(v), 3) for v in np.unique(np.round(ideal.real / 4096, 3))]
            out["rx"][backend]["packets"].append(rec)
    # comparison RTL vs python on the same samples
    comp = []
    for a, b in zip(out["rx"]["python"]["packets"], out["rx"]["rtl"]["packets"]):
        comp.append({"name": a["name"], "both_detected": a["detected"] and b["detected"],
                     "same_decisions": bool(a.get("payload_ok") == b.get("payload_ok") and a.get("byte_errors") == b.get("byte_errors")),
                     "same_mode": a.get("mode_used") == b.get("mode_used")})
    out["compare"] = comp
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="results/dualmode")
    ap.add_argument("--only", default=",".join(SCENARIOS))
    a = ap.parse_args()
    d = Path(a.out)
    d.mkdir(parents=True, exist_ok=True)
    res = {}
    for sid in a.only.split(","):
        res[sid] = run_scenario(sid, SCENARIOS[sid])
    (d / "scenario.json").write_text(json.dumps(res, indent=1, default=str))
    print("-> ", d / "scenario.json")


if __name__ == "__main__":
    main()
