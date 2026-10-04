#!/usr/bin/env python3
"""Analyse plutolink logs (copy the *_rx_packets.csv / *_rx_stats.csv [+ the tx files] to the PC).

usage: analyze_logs.py RX_PREFIX [--tx TX_PREFIX] [--out DIR]
  RX_PREFIX  the --log prefix used by `plutolink rx` (reads <prefix>_packets.csv)
  --tx       the --log prefix of `plutolink tx` (delivery ratio per sweep step)

Prints a per-step table (step_id = TX gain step of `plutolink tx --sweep`) and writes PNG plots:
  snr_vs_gain.png (SNR + RSSI), ber_vs_snr.png (BER, PER), time_series.png (SNR / RSSI / CFO over time)
"""
import argparse
import csv
import math
import os
import sys
from collections import defaultdict


def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def fnum(r, k, default=float("nan")):
    try:
        return float(r[k])
    except (KeyError, ValueError):
        return default


def mean(v):
    v = [x for x in v if not math.isnan(x)]
    return sum(v) / len(v) if v else float("nan")


def std(v):
    v = [x for x in v if not math.isnan(x)]
    if len(v) < 2:
        return float("nan")
    m = sum(v) / len(v)
    return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rx_prefix")
    ap.add_argument("--tx", dest="tx_prefix")
    ap.add_argument("--out", default=".")
    a = ap.parse_args()

    rx = load(a.rx_prefix + "_packets.csv") if os.path.exists(a.rx_prefix + "_packets.csv") else load(a.rx_prefix + "_rx_packets.csv")
    tx = []
    if a.tx_prefix:
        for cand in (a.tx_prefix + "_packets.csv", a.tx_prefix + "_tx_packets.csv"):
            if os.path.exists(cand):
                tx = load(cand)
                break
    if not rx:
        sys.exit("no rx packets in the log")

    sent = defaultdict(int)
    for r in tx:
        sent[int(float(r["step_id"]))] += 1

    steps = defaultdict(list)
    for r in rx:
        if int(fnum(r, "hdr_ok", 0)):
            steps[int(fnum(r, "step_id", 0))].append(r)
        else:
            steps[-1].append(r)          # header unreadable: cannot be assigned to a step

    print(f"{'step':>5} {'gain_dB':>8} {'sent':>6} {'rx':>6} {'deliv%':>7} {'crc_bad':>7} {'PER':>8} {'BER':>10} {'SNR dB':>7} "
          f"{'EVM%':>6} {'RSSI dBFS':>9} {'CFO Hz':>8} {'CFO sd':>7}")
    rows = []
    for sid in sorted(steps):
        rs = steps[sid]
        n = len(rs)
        bits = sum(fnum(r, "bits", 0) for r in rs)
        be = sum(fnum(r, "bit_errors", 0) for r in rs)
        crc_bad = sum(1 for r in rs if not int(fnum(r, "crc_ok", 0)))
        gain = mean([fnum(r, "tx_gain_db") for r in rs])
        snr = mean([fnum(r, "snr_db") for r in rs])
        evm = mean([fnum(r, "evm_pct") for r in rs])
        rssi = mean([fnum(r, "rssi_dbfs") for r in rs])
        cfo = [fnum(r, "cfo_hz") for r in rs]
        ns = sent.get(sid, 0)
        deliv = 100.0 * n / ns if ns else float("nan")
        per = crc_bad / n if n else float("nan")
        ber = be / bits if bits else float("nan")
        rows.append((sid, gain, ns, n, deliv, crc_bad, per, ber, snr, evm, rssi, mean(cfo), std(cfo)))
        print(f"{sid:>5} {gain:8.2f} {ns:6d} {n:6d} {deliv:7.1f} {crc_bad:7d} {per:8.2e} {ber:10.2e} {snr:7.1f} {evm:6.2f} {rssi:9.1f} "
              f"{mean(cfo):8.0f} {std(cfo):7.0f}")

    lost = sum(1 for r in rx if int(fnum(r, "hdr_ok", 0)) == 0)
    print(f"\ntotal rx records {len(rx)}, unreadable headers {lost}")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed: plots skipped")
        return
    os.makedirs(a.out, exist_ok=True)
    good = [r for r in rows if r[0] >= 0 and not math.isnan(r[1])]
    if good:
        fig, ax = plt.subplots(1, 2, figsize=(11, 4))
        ax[0].plot([r[1] for r in good], [r[8] for r in good], "o-")
        ax[0].set_xlabel("TX gain setting [dB]"); ax[0].set_ylabel("SNR from pilot EVM [dB]"); ax[0].grid(True)
        ax[1].plot([r[1] for r in good], [r[10] for r in good], "o-")
        ax[1].set_xlabel("TX gain setting [dB]"); ax[1].set_ylabel("RSSI [dBFS]"); ax[1].grid(True)
        fig.tight_layout(); fig.savefig(os.path.join(a.out, "snr_vs_gain.png"), dpi=120); plt.close(fig)

        fig, ax = plt.subplots(1, 2, figsize=(11, 4))
        ax[0].semilogy([r[8] for r in good], [max(r[7], 1e-8) for r in good], "o-")
        ax[0].set_xlabel("SNR [dB]"); ax[0].set_ylabel("BER (floor 1e-8)"); ax[0].grid(True, which="both")
        ax[1].semilogy([r[1] for r in good], [max(r[6], 1e-6) for r in good], "o-", label="PER (crc)")
        ax[1].semilogy([r[1] for r in good], [max(1 - r[4] / 100.0, 1e-6) if not math.isnan(r[4]) else 1e-6 for r in good], "s--", label="not delivered")
        ax[1].set_xlabel("TX gain setting [dB]"); ax[1].legend(); ax[1].grid(True, which="both")
        fig.tight_layout(); fig.savefig(os.path.join(a.out, "ber_vs_snr.png"), dpi=120); plt.close(fig)

    t = [fnum(r, "t_s") for r in rx]
    fig, ax = plt.subplots(3, 1, figsize=(10, 7), sharex=True)
    ax[0].plot(t, [fnum(r, "snr_db") for r in rx], ".", ms=3); ax[0].set_ylabel("SNR [dB]")
    ax[1].plot(t, [fnum(r, "rssi_dbfs") for r in rx], ".", ms=3); ax[1].set_ylabel("RSSI [dBFS]")
    ax[2].plot(t, [fnum(r, "cfo_hz") for r in rx], ".", ms=3); ax[2].set_ylabel("CFO [Hz]"); ax[2].set_xlabel("time [s]")
    for x in ax:
        x.grid(True)
    fig.tight_layout(); fig.savefig(os.path.join(a.out, "time_series.png"), dpi=120); plt.close(fig)
    print("plots written to", os.path.abspath(a.out))


if __name__ == "__main__":
    main()
