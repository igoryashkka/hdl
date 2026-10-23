"""Bit-exact check of tb_phy_tx_axis_bf dumps (sim/work/bf_dump_a1.txt, bf_dump_a2.txt) against python/bf_ref.py.
For every packet (G line: strobe index, strobes from apply to go, tick_phase, log2 P, launch index) the PHY output of both channels
(before the NCO) must equal tx_frame_bf with the weights the RTL had to use (mask / SOUND / ctrl, tau = tau_used + tick_adj), and
the DAC samples must equal the output NCO (phase = k * inc from the apply strobe) or the plain delay, with a constant latency.
Exit code 0 = pass."""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bf_ref

ROOT = os.path.join(os.path.dirname(__file__), "..", "sim")
meta = json.load(open(os.path.join(ROOT, "vec", "tbbf_meta.json")))
SYM = 2192
NSAMP = 5 * SYM                      # sync, LTS, header, 2 data symbols (MAX RANGE, 270 bytes)
# packets per board in the TB order: (channel mask, sound)
PKTS = {"a1": [(3, False), (2, True)], "a2": [(3, False)]}


def s16(v):
    return v - 65536 if v >= 32768 else v


def load(name):
    gos, S = [], {}
    for line in open(os.path.join(ROOT, "work", f"bf_dump_{name}.txt")):
        t = line.split()
        if not t:
            continue
        if t[0] == "G":
            gos.append(tuple(int(x) for x in t[1:]))
        elif t[0] == "S":
            k = int(t[1]); w = [int(x, 16) for x in t[3:]]
            S[k] = (int(t[2]), [(s16(x >> 16), s16(x & 0xFFFF)) for x in w])
    return gos, S


def chans_for(name, mask, sound, ntau, tick_adj):
    out = []
    for c, p in enumerate(meta[name]):
        if not (mask >> c) & 1:
            out.append(dict(mode="mute")); continue
        if sound or not p["weights"]:
            out.append(dict(mode="bypass" if tick_adj == 0 else "weight", amp=32767, phase=0, tau=tick_adj)); continue
        out.append(dict(mode="weight", amp=p["amp"], phase=p["phase"], tau=bf_ref.tau_used(p["tau"], p["rho"], ntau, tick_adj)))
    return out


def main():
    fails = 0
    lat_all = []
    for name in ("a1", "a2"):
        gos, S = load(name)
        gos = [g for g in gos if g[0] >= 0]
        if len(gos) != len(PKTS[name]):
            print(f"{name}: {len(gos)} packets in the dump, expected {len(PKTS[name])}"); fails += 1; continue
        ks = sorted(S)
        for (kgo, ntau, tp, lg, idx), (mask, sound) in zip(gos, PKTS[name]):
            adj = bf_ref.tick_adj(tp, lg)
            chans = chans_for(name, mask, sound, ntau, adj)
            exp = bf_ref.tx_frame_bf(meta["payload"], chans, code="ldpc", mode=0)
            k0 = next(k for k in ks if k >= kgo and S[k][0] == 1)
            lat_all.append(k0 - kgo)
            for c in range(2):
                got = [S[k0 + i][1][c] for i in range(NSAMP)]
                bad = sum(1 for a, b in zip(got, exp[c]) if a != b)
                if bad:
                    fails += 1
                    i = next(i for i in range(NSAMP) if got[i] != exp[c][i])
                    print(f"{name} pkt@{kgo} ch{c}: {bad} PHY samples differ, first #{i} got {got[i]} exp {exp[c][i]} ({chans[c]})")
            # NCO / delay: dac[k + L] = f(iq[k]) for the whole dumped range
            for c in range(2):
                p = meta[name][c]
                kk = np.array([k for k in ks if k + 3 in S])
                xr = np.array([S[k][1][c][0] for k in kk]); xi = np.array([S[k][1][c][1] for k in kk])
                if p["nco"]:
                    ph = (kk.astype(np.int64) * p["inc"]) & 0xFFFFFFFF
                    from rx_blocks_ref import nco_cs
                    cs, sn = nco_cs(ph)
                    yr = bf_ref.sat((xr * cs - xi * sn + 16384) >> 15); yi = bf_ref.sat((xr * sn + xi * cs + 16384) >> 15)
                else:
                    yr, yi = xr, xi
                ok_l = None
                for L in (1, 2, 3):
                    dr = np.array([S[k + L][1][2 + c][0] for k in kk]); di = np.array([S[k + L][1][2 + c][1] for k in kk])
                    if np.array_equal(dr, yr) and np.array_equal(di, yi):
                        ok_l = L; break
                if ok_l is None:
                    fails += 1; print(f"{name} pkt@{kgo} ch{c}: DAC stream does not match the {'NCO' if p['nco'] else 'delay'} model")
            print(f"{name}: packet at strobe {kgo} (launch index {idx}) mask {mask} sound {int(sound)} ntau {ntau} tick_phase {tp} "
                  f"-> tick_adj {adj}/256; first sample {k0 - kgo} strobes after go; channels {[c['mode'] for c in chans]}")
    if len(set(lat_all)) > 1:
        fails += 1; print("launch latency differs between packets:", lat_all)
    print("check_bf_axis:", "PASSED" if fails == 0 else f"FAILED ({fails})")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
