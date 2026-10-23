"""M1 report (TestTask006): array gain of two TX channels measured by the anchor (board B) from the anchor logs of bf_m1.ps1.
data_amp = channel amplitude of the data packet of an epoch (all active channels, weights in force), amp0 / amp1 = amplitudes of the
sounding packets of TX1 / TX2 (unit weight, same per-channel power). Gains are relative to the TX1-only data packet:
  measured gain (dB)          = 20 log10(data_amp / data_amp(ch0))
  ideal, same per-channel power = 20 log10((a0 + a1 * w1) / a0) with MRT weights (w = a / max a), 6.02 dB for equal channels
  at equal total power          = measured gain - 10 log10(1 + w1^2)  (TZ M1 criterion: >= ideal - 1.5 dB, ideal +3 dB)
usage: python bf_m1_report.py [--logs DIR]"""
import argparse, csv, math, os
import statistics as st


def load(fn, skip_s=3.0):
    rows = []
    with open(fn) as f:
        for r in csv.DictReader(f):
            if float(r["t_s"]) < skip_s or not r.get("data_amp") or float(r["data_amp"]) <= 0:
                continue
            rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", default=os.path.join(os.path.dirname(__file__), "logs"))
    a = ap.parse_args()
    res = {}
    for run in ("ch0", "hold", "bf"):
        fn = os.path.join(a.logs, f"bf_m1_{run}_anchor.csv")
        if not os.path.exists(fn):
            continue
        rows = load(fn)
        if not rows:
            print(f"{run}: no data packets in {fn}"); continue
        d = [float(r["data_amp"]) for r in rows]; a0 = [float(r["amp0"]) for r in rows]; a1 = [float(r["amp1"]) for r in rows]
        res[run] = {"n": len(rows), "data": st.median(d), "a0": st.median(a0), "a1": st.median(a1),
                    "snr0": st.median(float(r["snr0"]) for r in rows), "data_snr": st.median(float(r["data_snr"]) for r in rows)}
    if "ch0" not in res:
        print("no ch0 run: nothing to compare against"); return 1
    ref = res["ch0"]["data"]
    print(f"{'run':5s} {'epochs':>6s} {'data amp':>9s} {'gain dB':>8s} {'sound amp TX1/TX2':>18s} {'data SNR':>9s}")
    for run, r in res.items():
        print(f"{run:5s} {r['n']:6d} {r['data']:9.2f} {20 * math.log10(r['data'] / ref):8.2f} {r['a0']:8.2f}/{r['a1']:<8.2f} {r['data_snr']:9.1f}")
    if "bf" in res:
        a0, a1 = res["bf"]["a0"], res["bf"]["a1"]
        w1 = min(a0, a1) / max(a0, a1)
        if a1 > a0:
            ideal = 20 * math.log10((a0 * w1 + a1) / a0); ptot = 10 * math.log10(1 + w1 ** 2)
        else:
            ideal = 20 * math.log10((a0 + a1 * w1) / a0); ptot = 10 * math.log10(1 + w1 ** 2)
        g = 20 * math.log10(res["bf"]["data"] / ref)
        print(f"\nbeamforming: measured {g:+.2f} dB, ideal (MRT, same per-channel power) {ideal:+.2f} dB, loss {ideal - g:.2f} dB")
        print(f"at equal total power: measured {g - ptot:+.2f} dB vs ideal {ideal - ptot:+.2f} dB "
              f"(M1 criterion: >= ideal - 1.5 dB -> {'PASS' if ideal - g <= 1.5 else 'FAIL'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
