"""Cross-check of the C anchor estimator (beamd estimate FILE) against python/bf_anchor.py on the same int16 capture:
four sounding packets with the slot pattern of epoch e (S1 shifted by 64 * (e mod 8)), random delays / phases / CFO, noise.
usage: python sw/beamd/check_estimate.py [--beamd PATH] [--snr DB] [--epoch E]   (exit 0 = all fields agree)"""
import argparse, os, subprocess, sys, tempfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(ROOT, "python"))
sys.path.insert(0, os.path.join(ROOT, "phy_sim", "experiments"))
import bf_anchor  # noqa: E402
import bf_loop  # noqa: E402
import ofdm_ref  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--beamd", default=os.path.join(HERE, "beamd_host"))
    ap.add_argument("--snr", type=float, default=15.0)
    ap.add_argument("--epoch", type=int, default=5)
    ap.add_argument("--seed", type=int, default=3)
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    slots = bf_anchor.slots_for(a.epoch)
    n = slots[-1] + 20000
    x = np.zeros(n, dtype=complex)
    truth = []
    for k, s in enumerate(slots):
        t0 = s + 500 + rng.uniform(0, 1); ph = rng.uniform(0, 2 * np.pi); f = rng.uniform(-4000, 4000)
        x += bf_loop.place(bf_loop.XS, t0, n, 1.0, f, ph)
        truth.append((t0, ph, f))
    x += 10 ** (-a.snr / 20) * (rng.standard_normal(n) + 1j * rng.standard_normal(n)) / np.sqrt(2)
    qi = np.clip(np.round(x.real * 300), -2048, 2047); qq = np.clip(np.round(x.imag * 300), -2048, 2047)
    q = qi + 1j * qq
    raw = np.empty(2 * n, dtype=np.int16); raw[0::2] = q.real; raw[1::2] = q.imag
    xq = q.astype(complex)
    fn = os.path.join(tempfile.gettempdir(), "beamd_check.iq")
    raw.tofile(fn)

    # python
    dets = bf_anchor.detect(xq)
    py = [bf_anchor.estimate(xq, s0, P) for s0, P in dets]
    asg = bf_anchor.assign(dets)
    # C
    cmd = [a.beamd, "estimate", fn, "--nant", "4"]
    if os.name == "nt":                                   # the host build is a Linux binary: run it in WSL
        wslp = lambda w: "/mnt/" + w[0].lower() + w[2:].replace("\\", "/")
        cmd = ["wsl", "-e", wslp(os.path.abspath(a.beamd)), "estimate", wslp(fn), "--nant", "4"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.splitlines()
    rows = [l.split(",") for l in out if l and l[0].isdigit()]
    m8c = [int(l.split("=")[1]) for l in out if l.startswith("# assigned")]
    fails = 0
    lts = np.array([v for v, _ in ofdm_ref.preamble(1)])
    print(f"LTS positive bins (python) {int(np.sum(lts > 0))}, lag pairs python {[len(bf_anchor.LAG_PAIRS[m]) for m in bf_anchor.LAGS]}")
    if len(rows) != len(py):
        print(f"detections: C {len(rows)} python {len(py)}"); fails += 1
    for r, p in zip(rows, py):
        s, t, f, phi, amp, snr = int(r[1]), float(r[2]), float(r[3]), float(r[4]), float(r[5]), float(r[6])
        dphi = np.angle(np.exp(1j * (phi - p["phi"])))
        ok = s == dets[int(r[0])][0] and abs(t - p["t"]) < 1e-6 and abs(f - p["f"]) < 1e-3 and abs(dphi) < 1e-6 and abs(amp / p["amp"] - 1) < 1e-6
        fails += not ok
        print(f"#{r[0]} s_sync {s} t C {t:.6f} py {p['t']:.6f}  f {f:.3f}/{p['f']:.3f}  phi diff {dphi:.2e}  amp {amp:.3f}/{p['amp']:.3f}  "
              f"snr {snr:.1f}  {'ok' if ok else 'MISMATCH'}")
    if not asg or not m8c or m8c[0] != asg[1] or asg[1] != a.epoch % 8:
        print(f"slot assignment: C {m8c} python {asg[1] if asg else None} expected {a.epoch % 8}"); fails += 1
    # against the truth (relative to antenna 0, as the controller uses them)
    if asg:
        e0 = py[0]
        for k in range(1, 4):
            dt_est = (py[k]["t"] - slots[k]) - (e0["t"] - slots[0]); dt_true = (truth[k][0] - slots[k]) - (truth[0][0] - slots[0])
            print(f"antenna {k}: relative arrival error {dt_est - dt_true:+.4f} samples")
    print("check_estimate:", "PASSED" if fails == 0 else f"FAILED ({fails})")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
