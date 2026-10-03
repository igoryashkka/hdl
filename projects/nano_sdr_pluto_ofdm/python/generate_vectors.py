"""Generate stimulus + expected (golden) vectors for block testbenches -> sim/vec/*.mem (hex, one word/line).
Stimulus word layout (per clock): {last, first, valid, payload}. Gaps (valid=0) are random.
Deterministic seed => reproducible regression."""
import os, sys, random
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from phy_params import *
import qam_ref, scrambler_ref, crc_ref

OUT = os.path.join(os.path.dirname(__file__), "..", "sim", "vec")
os.makedirs(OUT, exist_ok=True)
rng = random.Random(1234)

def wr(name, words, width_hex):
    with open(os.path.join(OUT, name), "w") as f:
        for w in words:
            f.write(f"{w & ((1 << (4*width_hex)) - 1):0{width_hex}x}\n")

def with_gaps(items, p_gap=0.3):
    """items: list of (payload, first, last). returns list of (valid, first, last, payload) incl. idle cycles."""
    seq = []
    for it in items:
        while rng.random() < p_gap:
            seq.append((0, 0, 0, rng.getrandbits(16)))      # idle, garbage payload (must be ignored)
        seq.append((1, it[1], it[2], it[0]))
    seq += [(0, 0, 0, 0)] * 8
    return seq

def pack(seq, pw):
    return [(l << (pw+2)) | (f << (pw+1)) | (v << pw) | (p & ((1 << pw) - 1)) for v, f, l, p in seq]

def frames(n_frames, lens):
    out = []
    for _ in range(n_frames):
        n = rng.choice(lens)
        out.append([rng.getrandbits(8) for _ in range(n)])
    return out

# ---- scrambler: boundary frames (all 00 / all FF) + random, multiple frames (seed reload) ----
fr = [[0]*16, [255]*16] + frames(20, [1, 2, 7, 64, 200])
items, exp = [], []
for f in fr:
    s = scrambler_ref.scramble(f)
    for i, b in enumerate(f):
        items.append((b, int(i == 0), int(i == len(f)-1)))
    exp += s
seq = with_gaps(items)
wr("scr_stim.mem", pack(seq, 8), 3)
wr("scr_exp.mem", exp, 2)
print("scr", len(seq), len(exp))

# ---- crc: frames with appended good CRC (ok=1) and corrupted (ok=0) ----
items, exp_ok = [], []
for k, f in enumerate(frames(24, [1, 4, 33, 128]) + [[0]*8, [255]*8]):
    fc = crc_ref.append_crc(f)
    bad = (k % 3 == 2)
    if bad:
        fc[rng.randrange(len(fc))] ^= 1 << rng.randrange(8)
    for i, b in enumerate(fc):
        items.append((b, int(i == 0), int(i == len(fc)-1)))
    exp_ok.append((int(not bad), crc_ref.crc32_reg(fc) if True else 0))
seq = with_gaps(items)
wr("crc_stim.mem", pack(seq, 8), 3)
wr("crc_exp.mem", [(ok << 32) | reg for ok, reg in exp_ok], 9)
print("crc", len(seq), len(exp_ok))

# ---- QAM mapper (16-QAM default build; also 4 and 64 via separate files) ----
for order in (4, 16, 64):
    bps = order.bit_length() - 1
    n = 1 << bps
    bits = list(range(n)) + [rng.randrange(n) for _ in range(500)]   # every symbol + random
    items = [(b, 0, int(i == len(bits)-1)) for i, b in enumerate(bits)]
    bitarr = np.array([[(b >> (bps-1-k)) & 1 for k in range(bps)] for b in bits])
    iq = qam_ref.map_symbols(bitarr.reshape(-1), order=order)
    seq = with_gaps(items)
    wr(f"map{order}_stim.mem", pack(seq, 6), 3)
    wr(f"map{order}_exp.mem", [((int(i) & 0xFFFF) << 16) | (int(q) & 0xFFFF) for i, q in iq], 8)
    # ---- demapper: noisy + boundary (full-scale +-32767/-32768) inputs ----
    pts = [(32767, 32767), (-32768, -32768), (0, 0), (32767, -32768), (-1, 1)]
    ideal = iq.copy()
    noise = np.array([[rng.gauss(0, 2500), rng.gauss(0, 2500)] for _ in range(len(ideal))])
    noisy = np.clip(np.round(ideal + noise), -32768, 32767).astype(np.int64)
    allpts = np.vstack([np.array(pts), noisy])
    llr = qam_ref.demap_llr(allpts, order=order)
    items = [(((int(i) & 0xFFFF) << 16) | (int(q) & 0xFFFF), 0, int(k == len(allpts)-1)) for k, (i, q) in enumerate(allpts)]
    seq = with_gaps(items)
    wr(f"dem{order}_stim.mem", pack(seq, 32), 9)
    exp = []
    for row in llr:
        w = 0
        for v in row:
            w = (w << 8) | (int(v) & 0xFF)
        exp.append(w)
    wr(f"dem{order}_exp.mem", exp, 2 * bps)
    print("map/dem", order, len(seq), len(llr))
    # hard-decision sanity: noiseless LLR sign must reproduce bits
    l0 = qam_ref.demap_llr(ideal, order=order)
    hard = (l0 < 0).astype(int).reshape(-1)
    assert (hard == bitarr.reshape(-1)).all(), "demapper sign != mapped bits"

# ---- FFT core: TAG -> (n_log, shift_mask, amplitude). Frames back-to-back + 1 zero flush frame. ----
import fft_ref
FFT_CFGS = {1: (4, 0xF, 12000), 2: (6, 0x3F, 30000), 3: (11, 0x0FF, 12000), 4: (4, 0x0, 32767), 5: (11, 0x7FF, 20000)}
for tag, (nl, mask, amp) in FFT_CFGS.items():
    N = 1 << nl
    nfr = 3 if nl > 6 else 5
    frs = [(np.array([rng.randint(-amp, amp) for _ in range(N)]), np.array([rng.randint(-amp, amp) for _ in range(N)])) for _ in range(nfr)]
    frs[0] = (np.full(N, amp), np.full(N, -amp))                      # boundary: constant full-scale
    exp = []
    for xr, xi in frs:
        yr, yi = fft_ref.fft_fixed(xr, xi, nl, 18, mask)
        exp += [(((int(a) & 0x3FFFF) << 18) | (int(b) & 0x3FFFF)) for a, b in zip(yr, yi)]
    wr(f"fft{tag}_exp.mem", exp, 9)
    samples = [(int(a), int(b)) for xr, xi in frs for a, b in zip(xr, xi)] + [(0, 0)] * N
    for kind, pg in (("c", 0.0), ("g", 0.25)):
        seq = []
        for a, b in samples:
            while rng.random() < pg:
                seq.append((0, rng.randint(-30000, 30000), rng.randint(-30000, 30000)))
            seq.append((1, a, b))
        seq += [(0, 0, 0)] * 40
        wr(f"fft{tag}_{kind}_in.mem", [((v << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)) for v, a, b in seq], 9)
    print("fft", tag, nl, hex(mask), len(exp))

# ---- interleaver / deinterleaver: TAG -> (deint, width, rot_unit, rows, cols) ----
import interleaver_ref as ilr
ITL_CFGS = {1: (0, 4, 1, 55, 20), 2: (1, 4, 1, 55, 20), 3: (0, 32, 8, 55, 20), 4: (1, 32, 8, 55, 20),
            5: (0, 4, 1, 5, 4), 6: (1, 4, 1, 5, 4)}
for tag, (de, wd, un, rows, cols) in ITL_CFGS.items():
    n = rows * cols
    words = [rng.getrandbits(wd) for _ in range(3 * n)]
    exp = (ilr.deinterleave if de else ilr.interleave)(words, wd, un, rows, cols)
    hexw = (wd + 3) // 4
    wr(f"itl{tag}_in.mem", words, hexw)
    wr(f"itl{tag}_exp.mem", exp, hexw)

# ---- ofdm mapper / pilot insert / preamble ----
import ofdm_ref as ofr
NSYMB = 2
qam_all = [[(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(NUM_DATA_SC)] for _ in range(NSYMB)]
wr("ofm_in.mem", [((i & 0xFFFF) << 16) | (q & 0xFFFF) for sy in qam_all for i, q in sy], 8)
bins_all = [ofr.map_bins(sy) for sy in qam_all]
wr("ofm_exp.mem", [(f << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF) for bl in bins_all for f, a, b in bl], 9)
# pilot insert: stimulus {first,last,pilot,valid,re,im}, with gaps
items = []
for bl in bins_all:
    for k, (f, a, b) in enumerate(bl):
        items.append((((int(k == 0) << 34) | (int(k == FFT_SIZE - 1) << 33) | (f << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)), 0, 0))
seq = []
for it in items:
    while rng.random() < 0.25:
        seq.append((0, rng.getrandbits(36)))
    seq.append((1, it[0]))
seq += [(0, 0)] * 8
wr("pil_in.mem", [(v << 35) | (w & 0x7FFFFFFFF) for v, w in seq], 9)
exp = []
for bl in bins_all:
    for a, b in ofr.insert_pilots(bl):
        exp.append(((a & 0xFFFF) << 16) | (b & 0xFFFF))
wr("pil_exp.mem", exp, 8)
for kind in (0, 1):
    wr(f"pre{kind}_exp.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in ofr.preamble(kind)], 8)

# ---- IFFT wrapper: TAG -> (n_log, mask, amp);  files ifw{TAG}_{c,g}_in / _exp (16-bit saturated outputs) ----
import tx_ref
IFW_CFGS = {1: (4, 0xF, 30000), 2: (4, 0x0, 32767), 3: (11, 0x0FF, 8000)}
for tag, (nl, mask, amp) in IFW_CFGS.items():
    N = 1 << nl
    nfr = 3 if nl > 6 else 5
    frs = [(np.array([rng.randint(-amp, amp) for _ in range(N)]), np.array([rng.randint(-amp, amp) for _ in range(N)])) for _ in range(nfr)]
    frs[0] = (np.full(N, amp), np.full(N, -amp))
    exp = []
    for xr, xi in frs:
        yr, yi = tx_ref.ifft_raw(xr, xi, nl, mask)
        exp += [(((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF)) for a, b in zip(yr, yi)]
    wr(f"ifw{tag}_exp.mem", exp, 8)
    samples = [(int(a), int(b)) for xr, xi in frs for a, b in zip(xr, xi)] + [(0, 0)] * (N - 1)
    for kind, pg in (("c", 0.0), ("g", 0.25)):
        seq = []
        for a, b in samples:
            while rng.random() < pg:
                seq.append((0, rng.randint(-30000, 30000), rng.randint(-30000, 30000)))
            seq.append((1, a, b))
        seq += [(0, 0, 0)] * 40
        wr(f"ifw{tag}_{kind}_in.mem", [((v << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)) for v, a, b in seq], 9)

# ---- TX scaler: TAG -> gain ----
SCL_GAINS = {1: 16384, 2: 8192, 3: 65535, 4: 0, 5: 24000}
base_pts = [(32767, -32768), (-32768, 32767), (0, 0), (1, -1), (-32768, -32768), (32767, 32767)]
pts = base_pts + [(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(1500)]
for tag, g in SCL_GAINS.items():
    exp = [((int(tx_ref.tx_scale([a], g)[0]) & 0xFFFF) << 16) | (int(tx_ref.tx_scale([b], g)[0]) & 0xFFFF) for a, b in pts]
    wr(f"scl{tag}_exp.mem", exp, 8)
    seq = []
    for a, b in pts:
        while rng.random() < 0.3:
            seq.append((0, rng.getrandbits(16), rng.getrandbits(16)))
        seq.append((1, a, b))
    seq += [(0, 0, 0)] * 8
    wr(f"scl{tag}_in.mem", [((v << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)) for v, a, b in seq], 9)

# ---- CP insert / reorder: TAG -> (n_log, cp) ----
CP_CFGS = {1: (4, 4), 2: (11, 144), 3: (5, 0)}
for tag, (nl, cp) in CP_CFGS.items():
    N = 1 << nl
    nfr = 4 if nl < 8 else 3
    frs = [([rng.randint(-32768, 32767) for _ in range(N)], [rng.randint(-32768, 32767) for _ in range(N)]) for _ in range(nfr)]
    wr(f"cpi{tag}_in.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for fr in frs for a, b in zip(*fr)], 8)
    exp = []
    for fr in frs:
        yr, yi = tx_ref.cp_insert(fr[0], fr[1], nl, cp)
        exp += [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(yr, yi)]
    wr(f"cpi{tag}_exp.mem", exp, 8)

# ---- full TX chain: two packets (1100 bytes = 2 symbols, 700 bytes padded to 2 symbols) ----
txp = [[rng.getrandbits(8) for _ in range(n)] for n in (1100, 700)]
for k, pk in enumerate(txp):
    wr(f"txt_pkt{k}_in.mem", pk, 2)
    wr(f"txt_pkt{k}_exp.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in tx_ref.tx_frame(pk)], 8)
print("OK vectors in", OUT)
