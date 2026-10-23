"""Cross-check of the C controller (beamd ctltest FILE: Kalman filters, alias guard, NCO scheduling, parameters) against
python/bf_anchor.py Controller on the same epoch sequence. The sequence comes from a closed-loop run of
phy_sim/experiments/bf_loop.py (4 antennas, 10 ms epochs, SNR 10 dB so the alias guard acts). Parameters must agree to 1 LSB.
usage: python sw/beamd/check_ctl.py [--beamd PATH]   (exit 0 = agree)"""
import argparse, os, subprocess, sys, tempfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(ROOT, "python"))
sys.path.insert(0, os.path.join(ROOT, "phy_sim", "experiments"))
import bf_anchor  # noqa: E402
import bf_loop  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--beamd", default=os.path.join(HERE, "beamd_host"))
    ap.add_argument("--snr", type=float, default=10.0)
    a = ap.parse_args()
    # record what the loop feeds its controller
    rec = []
    upd, par = bf_anchor.Controller.update, bf_anchor.Controller.params

    def upd_rec(self, ests, slots=None):
        rec.append({"ests": [dict(e) if e else None for e in ests], "slots": list(self.slots if slots is None else slots)})
        return upd(self, ests, slots)

    def par_rec(self, t_tick, t_data, slots_next=None):
        rec[-1]["tt"], rec[-1]["td"] = t_tick, t_data
        return par(self, t_tick, t_data, slots_next)
    bf_anchor.Controller.update, bf_anchor.Controller.params = upd_rec, par_rec
    bf_loop.run(dict(bf_loop.OSC, lw=0.01), epochs=80, epoch_ms=10, snr_db=a.snr, seed=4)
    bf_anchor.Controller.update, bf_anchor.Controller.params = upd, par
    rec = [r for r in rec if "tt" in r]

    # python replay in a fresh controller, input file for C
    ctl = bf_anchor.Controller(bf_loop.SLOTS, bf_loop.LD, bf_loop.FC)
    exp, lines = [], []
    for r in rec:
        ctl.update(r["ests"], r["slots"])
        pr, nco = ctl.params(r["tt"], r["td"])
        for b in range(2):
            ctl.nco_change(r["tt"], b, nco[b])
        exp.append([pr[k // 2][k % 2] for k in range(4)])
        f = f"{r['tt']:.17g} {r['td']:.17g} 1 " + " ".join(f"{s:.17g}" for s in r["slots"])
        for e in r["ests"]:
            f += " 0 0 0 0 0" if e is None else f" 1 {e['t']:.17g} {e['f']:.17g} {e['phi']:.17g} {e['amp']:.17g}"
        lines.append(f)
    fn = os.path.join(tempfile.gettempdir(), "beamd_ctl.txt")
    open(fn, "w").write("\n".join(lines) + "\n")
    cmd = [a.beamd, "ctltest", fn, "--nant", "4", "--ld", str(bf_loop.LD), "--freq", str(bf_loop.FC)]
    if os.name == "nt":
        wslp = lambda w: "/mnt/" + w[0].lower() + w[2:].replace("\\", "/")
        cmd = ["wsl", "-e", wslp(os.path.abspath(a.beamd))] + [wslp(fn) if c == fn else c for c in cmd[1:]]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.split("\n")
    worst, n = 0, 0
    for i, (line, e) in enumerate(zip(out, exp)):
        v = [int(x) for x in line.split()]
        for k in range(4):
            got = v[5 * k:5 * k + 5]
            want = [e[k]["amp"], e[k]["phase"], e[k]["tau"], e[k]["rho"], e[k]["inc"]]
            d = [abs(g - w) for g, w in zip(got, want)]
            d[1] = min(d[1], 65536 - d[1]); d[4] = min(d[4], (1 << 32) - d[4])
            # rho / inc are rounded from values ~1e5 .. 1e8 LSB: allow 1 LSB; phase / tau / amp 1 LSB
            worst = max(worst, max(d)); n += 1
            if max(d) > 1:
                print(f"epoch {i} antenna {k}: C {got} python {want}")
    print(f"check_ctl: {len(exp)} epochs x 4 antennas, max difference {worst} LSB ->", "PASSED" if worst <= 1 else "FAILED")
    return 0 if worst <= 1 else 1


if __name__ == "__main__":
    sys.exit(main())
