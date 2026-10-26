"""Vectors for the beamforming blocks (TestTask006) -> sim/vec/bf_*.mem. Deterministic (seeded).
  bf_w_stim / bf_w_exp      : phy_tx_weight (frames with gaps, per-frame load of mode/amp/phase/tau, bin_rst)
  bf_tt_stim / bf_tt_exp    : phy_tau_track (random set / strobe / rho, tau_now after every clock)
  bf_nco_*                  : output NCO stream (strobe sequence, inc changes, enable changes)
  bf_txt_*                  : phy_tx_top BF=1 (two channels, per-frame weights), see tb_phy_tx_top
  bf_bus_*                  : phy_syncbus frames (PARAMS, SET_EPOCH, other, corrupted) and expected parsed fields
"""
import os, sys, random
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bf_ref
from phy_params import FFT_SIZE

OUT = os.path.join(os.path.dirname(__file__), "..", "sim", "vec")
os.makedirs(OUT, exist_ok=True)
rng = random.Random(6006)
N = FFT_SIZE


def wr(name, words, width_hex):
    with open(os.path.join(OUT, name), "w") as f:
        for w in words:
            f.write(f"{int(w) & ((1 << (4 * width_hex)) - 1):0{width_hex}x}\n")


def m(v, w):
    return int(v) & ((1 << w) - 1)


# ------------------------------------------------------------------ phy_tx_weight
# stim word: {load, mode[2], amp[16], phase[16], tau[17], bin_rst, valid, re[16], im[16]}  (86 bits -> 22 hex)
frames = [("bypass", 32767, 0, 0), ("weight", 23170, 8192, 0), ("weight", 32767, 51234, 3 * 256 + 77),
          ("weight", 9000, 1, -(40 * 256 + 3)), ("mute", 32767, 0, 0), ("weight", 32767, 0, 0),
          ("weight", 32767, 65535, 65535), ("weight", 0, 0, 0)]
MODE = {"bypass": 0, "weight": 1, "mute": 2}
stim, exp = [], []
for fi, (mode, amp, ph, tau) in enumerate(frames):
    re = np.array([rng.randint(-32768, 32767) if fi == 6 else rng.randint(-12000, 12000) for _ in range(N)])
    im = np.array([rng.randint(-32768, 32767) if fi == 6 else rng.randint(-12000, 12000) for _ in range(N)])
    if fi == 0:
        re[:4] = [32767, -32768, 0, -1]; im[:4] = [-32768, 32767, 1, 0]
    yr, yi = bf_ref.apply_weight(re, im, amp, ph, tau, mode)
    exp += [(m(a, 16) << 16) | m(b, 16) for a, b in zip(yr, yi)]
    brst = 0 if fi == 3 else 1                                 # frame 3 relies on the natural wrap of the bin counter
    stim.append((1 << 85) | (MODE[mode] << 83) | (m(amp, 16) << 67) | (m(ph, 16) << 51) | (m(tau, 17) << 34) | (brst << 33))
    for _ in range(3):
        stim.append(0)
    for k in range(N):
        while rng.random() < 0.2:
            stim.append(m(rng.getrandbits(32), 32))            # idle cycle, garbage data
        stim.append((1 << 32) | (m(re[k], 16) << 16) | m(im[k], 16))
    for _ in range(20):
        stim.append(0)
wr("bf_w_stim.mem", stim, 22)
wr("bf_w_exp.mem", exp, 8)
print("bf_w", len(stim), len(exp))

# ------------------------------------------------------------------ phy_tau_track
# stim: {set, strobe, tau_set[16], rho[32]} ; exp: tau_now (16) after the clock edge of that stim
acc = 0
stim, exp = [], []
for i in range(6000):
    st = int(rng.random() < 0.004) if i > 0 else 1
    sb = int(rng.random() < 0.25)
    ts = rng.choice([0, 1, -1, 32767, -32768, rng.randint(-20000, 20000)])
    rho = rng.choice([0, 1, -1, 4295, -4295, rng.randint(-(1 << 31), (1 << 31) - 1) if i > 3000 else rng.randint(-400000, 400000)])
    if st:
        acc = int(ts) << 24
    elif sb:
        acc = acc + rho
        acc = ((acc + (1 << 47)) % (1 << 48)) - (1 << 47)            # 48-bit register wraps
    hi = acc >> 24
    stim.append((st << 49) | (sb << 48) | (m(ts, 16) << 32) | m(rho, 32))
    exp.append(m(max(-32768, min(32767, hi)), 16))
wr("bf_tt_stim.mem", stim, 13)
wr("bf_tt_exp.mem", exp, 4)
print("bf_tt", len(stim))

# ------------------------------------------------------------------ output NCO stream (per strobe: {en, inc[32], re, im})
n = 5000
xr = np.array([rng.randint(-20000, 20000) if (i // 700) % 3 else 0 for i in range(n)])
xi = np.array([rng.randint(-20000, 20000) if (i // 700) % 3 else 0 for i in range(n)])
xr[100:104] = [32767, -32768, 32767, -32768]; xi[100:104] = [-32768, 32767, 32767, -32768]
incs = np.zeros(n, dtype=np.int64); ens = np.ones(n, dtype=np.int64)
cur, cen = 0, 1
for i in range(n):
    if i % 613 == 0:
        cur = rng.choice([0, 1, -1 & 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, rng.getrandbits(32), 4194304, (-12345678) & 0xFFFFFFFF])
    if i % 1777 == 1000:
        cen ^= 1
    incs[i] = cur; ens[i] = cen
ph = 0
er, ei = [], []
for i in range(n):
    yr, yi, ph = bf_ref.nco_stream([xr[i]], [xi[i]], [incs[i]], ph, bool(ens[i]))
    er.append(int(yr[0])); ei.append(int(yi[0]))
wr("bf_nco_stim.mem", [(int(ens[i]) << 64) | (m(incs[i], 32) << 32) | (m(xr[i], 16) << 16) | m(xi[i], 16) for i in range(n)], 17)
wr("bf_nco_exp.mem", [(m(a, 16) << 16) | m(b, 16) for a, b in zip(er, ei)], 8)
print("bf_nco", n)

# ------------------------------------------------------------------ phy_tx_top BF=1 : two packets, per-frame weights for 2 channels
# MAX RANGE (QPSK, LDPC 1/2), 270 / 200 byte packets = 2 data symbols (frame = 5 symbols)
pk = [[rng.getrandbits(8) for _ in range(270)], [rng.getrandbits(8) for _ in range(200)]]
cfgs = [[dict(mode="bypass"), dict(mode="weight", amp=23170, phase=12000, tau=-(2 * 256 + 50))],
        [dict(mode="weight", amp=30000, phase=60000, tau=5 * 256 + 3), dict(mode="mute")]]
words = []
for k in range(2):
    wr(f"bf_txt_pkt{k}_in.mem", pk[k], 2)
    outs = bf_ref.tx_frame_bf(pk[k], cfgs[k], code="ldpc", mode=0)
    for c in range(2):
        wr(f"bf_txt_pkt{k}_ch{c}_exp.mem", [(m(a, 16) << 16) | m(b, 16) for a, b in outs[c]], 8)
    for c in range(2):
        d = cfgs[k][c]
        words.append((MODE[d["mode"]] << 49) | (m(d.get("amp", 32767), 16) << 33) | (m(d.get("phase", 0), 16) << 17) | m(d.get("tau", 0), 17))
wr("bf_txt_cfg.mem", words, 13)
print("bf_txt ok")

# ------------------------------------------------------------------ syncbus: frames leader -> follower, expected parse
fr_list = []
for i in range(12):
    if i in (3, 8):
        f = bf_ref.frame(bf_ref.T_SET_EPOCH, i, bf_ref.le(rng.getrandbits(32), 4))
    elif i in (5,):
        f = bf_ref.frame(0x33, i, [rng.getrandbits(8) for _ in range(rng.randint(0, 40))])
    else:
        ch = [dict(amp=rng.getrandbits(15), phase=rng.getrandbits(16), tau=rng.randint(-16000, 16000), weights=rng.random() < 0.7,
                   nco=rng.random() < 0.5, rho=rng.randint(-(1 << 31), (1 << 31) - 1), inc=rng.getrandbits(32)) for _ in range(2)]
        f = bf_ref.params_frame(i, rng.choice([0xFFFFFFFF, rng.getrandbits(32)]), ch[0], ch[1])
    good = i not in (2, 9)
    if not good:
        f = list(f); f[rng.randrange(5, len(f))] ^= 1 << rng.randrange(8)
    fr_list.append((f, good))
# stim: per frame: {good, len[8]} then bytes ; exp per good frame: type, seq, payload words
with open(os.path.join(OUT, "bf_bus_frames.mem"), "w") as fo:
    for f, good in fr_list:
        fo.write(f"{(int(good) << 8) | len(f):03x}\n")
        for b in f:
            fo.write(f"{b:03x}\n")
    fo.write("fff\n")
print("bf_bus", len(fr_list))

# ------------------------------------------------------------------ tb_phy_tx_axis_bf: two boards (A1 leader, A2 follower)
import json
BFS = {
    "period": 12000, "launch1": 2000, "launch2": 500, "epoch0": 100, "target": 103,
    "a1": [dict(amp=30000, phase=1000, tau=300, weights=True, nco=True, rho=100000, inc=0x00123456),
           dict(amp=20000, phase=40000, tau=-500, weights=True, nco=False, rho=-70000, inc=0)],
    "a2": [dict(amp=32767, phase=0, tau=0, weights=False, nco=True, rho=0, inc=0xFFF00000),
           dict(amp=25000, phase=20000, tau=1000, weights=True, nco=True, rho=12345, inc=0x00010000)],
}
pay = [rng.getrandbits(8) for _ in range(270)]
wr("tbbf_pkt.mem", pay, 2)
def par_words(ch):
    return [(m(ch["phase"], 16) << 16) | m(ch["amp"], 16), ((int(ch["weights"]) | (int(ch["nco"]) << 1)) << 16) | m(ch["tau"], 16),
            m(ch["rho"], 32), m(ch["inc"], 32)]
wr("tbbf_a1par.mem", par_words(BFS["a1"][0]) + par_words(BFS["a1"][1]), 8)
f_set = bf_ref.frame(bf_ref.T_SET_EPOCH, 1, bf_ref.le(BFS["epoch0"] + 1, 4))
f_par = bf_ref.params_frame(2, BFS["target"], BFS["a2"][0], BFS["a2"][1])
wr("tbbf_frames.mem", [len(f_set)] + f_set + [len(f_par)] + f_par, 2)
json.dump({**BFS, "payload": pay}, open(os.path.join(OUT, "tbbf_meta.json"), "w"))
print("tbbf frames", len(f_set), len(f_par))

# ------------------------------------------------------------------ continuous / streaming frames (tb_phy_tx_cont): per mode
import tx_ref
for mode, na, tag in ((0, 5400, "cq"), (1, 13500, "cr")):
    lens = [na, 200 if mode == 0 else 500, 270 if mode == 0 else 900, 40]           # cont (> ring), normal, cont, cont shorter than the pre-fill
    for k, n in enumerate(lens):
        pk = [rng.getrandbits(8) for _ in range(n)]
        wr(f"{tag}_pkt{k}_in.mem", pk, 2)
        fr = tx_ref.tx_frame(pk, code="ldpc", mode=mode)
        wr(f"{tag}_pkt{k}_exp.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in fr], 8)
    print("cont", tag, [len(tx_ref.tx_frame([0] * n, code="ldpc", mode=mode)) // 2192 for n in lens], "symbols per frame")
