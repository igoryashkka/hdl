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

# ---- coded TX chain: two packets (900 bytes = 2 symbols, 500 bytes padded to 2 symbols) ----
txc = [[rng.getrandbits(8) for _ in range(n)] for n in (900, 500)]
for k, pk in enumerate(txc):
    wr(f"txc_pkt{k}_in.mem", pk, 2)
    wr(f"txc_pkt{k}_exp.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for a, b in tx_ref.tx_frame(pk, code="ldpc")], 8)

# ---- Schmidl-Cox detector: TAG -> (snr_db, cfo_hz, lead, paths) ; tag 2 = noise only (no event expected) ----
import channel_ref, sync_ref, sync_test, rx_test
_pay, _x = rx_test.make_frame()
SYNC_CFGS = {1: (15, 6000.0, 777, ((0, 1),)), 2: (None, 0.0, 0, None), 3: (8, -9000.0, 1500, ((0, 1), (20, 0.6)))}
for tag, (snr, cfo, lead, paths) in SYNC_CFGS.items():
    if snr is None:
        rr = np.random.default_rng(9)
        i_a = np.round(rr.normal(0, 100, 9000)).astype(np.int64); q_a = np.round(rr.normal(0, 100, 9000)).astype(np.int64)
    else:
        r = channel_ref.apply_channel(_x, snr_db=snr, cfo_hz=cfo, paths=paths, lead=lead, trail=3000, seed=tag)
        i_a, q_a = sync_test.adc(r)
    ev = sync_ref.detect(i_a, q_a)
    words = [(1 << 32) | ((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(i_a, q_a)]
    wr(f"syn{tag}_in.mem", words, 9)
    lines = [1 if ev else 0, ev["n_decl"] if ev else 0, ev["n_best"] if ev else 0, (ev["p_re"] & ((1 << 40) - 1)) if ev else 0, (ev["p_im"] & ((1 << 40) - 1)) if ev else 0, ev["r_best"] if ev else 0]
    with open(os.path.join(OUT, f"syn{tag}_exp.mem"), "w") as f:
        for k, v in enumerate(lines):
            f.write(("%0*x" % (1 if k == 0 else 10, v)) + chr(10))
    print("sync", tag, len(words), "event" if ev else "no event", ev and (ev["n_decl"], ev["n_best"]))

# ---- RX small blocks: dc_remove (TAG->K), input_scale (TAG->sh), nco_mixer (TAG->inc) ----
import rx_blocks_ref as rb
def gapseq(items, pg=0.3, width=1):
    seq = []
    for it in items:
        while rng.random() < pg:
            seq.append((0, rng.getrandbits(32)))
        seq.append((1, it))
    return seq + [(0, 0)] * 12
DC_K = {1: 10, 2: 4}
dcx = [rng.randint(-2048, 2047) + 700 for _ in range(1500)] + [32767] * 40 + [-32768] * 40 + [rng.randint(-32768, 32767) for _ in range(300)] + [0] * 100
for tag, K in DC_K.items():
    seq = gapseq(dcx)
    wr(f"dcr{tag}_in.mem", [(v << 16) | (w & 0xFFFF) for v, w in [(a, (b if a else 0)) for a, b in seq]], 5)
    wr(f"dcr{tag}_exp.mem", [o & 0xFFFF for o in rb.dc_remove(dcx, K)], 4)
SCL_SH = {1: 0, 2: 3, 3: -3, 4: 7, 5: -8}
sx = [32767, -32768, 0, 1, -1, 4095, -4096, 2047, -2048] + [rng.randint(-32768, 32767) for _ in range(800)]
for tag, sh in SCL_SH.items():
    seq = gapseq(sx)
    wr(f"isc{tag}_in.mem", [(a << 16) | (b & 0xFFFF if a else 0) for a, b in seq], 5)
    wr(f"isc{tag}_exp.mem", [o & 0xFFFF for o in rb.input_scale(sx, sh)], 4)
NCO_INC = {1: 0, 2: 1 << 28, 3: (-123456789) & 0xFFFFFFFF, 4: 0x01234567, 5: (1 << 31)}
nx = [(32767, -32768), (-32768, 32767), (0, 0), (1000, -1000)] + [(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(1500)]
for tag, inc in NCO_INC.items():
    seq = gapseq([(a << 16) | (b & 0xFFFF) for a, b in nx])
    wr(f"nco{tag}_in.mem", [(v << 32) | (w & 0xFFFFFFFF if v else 0) for v, w in seq], 9)
    yr, yi = rb.nco_mix([a for a, b in nx], [b for a, b in nx], inc)
    wr(f"nco{tag}_exp.mem", [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(yr, yi)], 8)

# ---- CORDIC vectoring and coarse CFO ----
import sync_ref as sr
cv = [(0, 0), (131071, 0), (0, 131071), (-131072, 0), (0, -131072), (-131072, -131072), (131071, 131071), (1, 0), (0, -1), (-1, 0), (-1, -1)]
cv += [(rng.randint(-131072, 131071), rng.randint(-131072, 131071)) for _ in range(500)]
cv += [(rng.randint(-50, 50), rng.randint(-50, 50)) for _ in range(60)]
wr("cor_in.mem", [((x & 0x3FFFF) << 18) | (y & 0x3FFFF) for x, y in cv], 9)
wr("cor_exp.mem", [sr.cordic_vec(x, y) for x, y in cv], 8)
pv = [(1 << 17, 0), (0, 1 << 17), (-(1 << 39), 0), ((1 << 39) - 1, (1 << 39) - 1), (-(1 << 39), -(1 << 39)), (200000, -150000)]
for _ in range(400):
    mag = rng.randint(17, 39)
    pv.append((rng.randint(-(1 << mag), (1 << mag) - 1), rng.randint(-(1 << mag), (1 << mag) - 1)))
pv = [(a, b) if max(abs(a), abs(b)) >= (1 << 16) else (a * 0 + (1 << 17), b) for a, b in pv]
wr("cfc_in.mem", [((a & ((1 << 40) - 1)) << 40) | (b & ((1 << 40) - 1)) for a, b in pv], 20)
wr("cfc_exp.mem", [sr.cfo_inc(a, b) for a, b in pv], 8)

# ---- RX FFT + reorder: TAG -> (n_log, mask, amp) ; frames separated by idle time in the TB, flush = N-1 zeros ----
import rx_fixed_ref as rfx
RXF_CFGS = {1: (4, 0xF, 3000), 2: (4, 0x0, 30000), 3: (11, 0x00F, 700)}
for tag, (nl, mask, amp) in RXF_CFGS.items():
    N = 1 << nl
    frs = [(np.array([rng.randint(-amp, amp) for _ in range(N)]), np.array([rng.randint(-amp, amp) for _ in range(N)])) for _ in range(3)]
    frs[0] = (np.full(N, amp), np.full(N, -amp))
    exp = []
    for xr, xi in frs:
        yr, yi = rfx.rx_fft(xr, xi, mask, nl)
        exp += [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(yr, yi)]
    wr(f"rxf{tag}_exp.mem", exp, 8)
    wr(f"rxf{tag}_in.mem", [((a & 0xFFFF) << 16) | (b & 0xFFFF) for xr, xi in frs for a, b in zip(xr, xi)], 8)

# ---- bin select / channel estimator / equalizer ----
def pack_w(mr, mi, E):
    return ((mr & 0xFFFF) << 24) | ((mi & 0xFFFF) << 8) | (E & 0xFF)
SEL_FRAMES = 2
import ofdm_ref as _ofr
sel_in, sel_exp = [], []
for f in range(SEL_FRAMES):
    yr = np.array([rng.randint(-32768, 32767) for _ in range(FFT_SIZE)]); yi = np.array([rng.randint(-32768, 32767) for _ in range(FFT_SIZE)])
    sel_in += [(int(b == 0) << 32) | ((int(yr[b]) & 0xFFFF) << 16) | (int(yi[b]) & 0xFFFF) for b in range(FFT_SIZE)]
    ar, ai = rfx.select_active(yr, yi)
    for k in range(NUM_ACTIVE_SC):
        sel_exp.append((int(_ofr.is_pilot_slot(k)) << 34) | (int(k == 0) << 33) | (int(k == NUM_ACTIVE_SC - 1) << 32) | ((int(ar[k]) & 0xFFFF) << 16) | (int(ai[k]) & 0xFFFF))
wr("bsl_in.mem", sel_in, 9)
wr("bsl_exp.mem", sel_exp, 9)
# channel estimator: Y streams (boundary + random + small + zero), TAG -> frame count
ce_frames = []
fr = [(0, 0)] * 40 + [(32767, 32767), (-32768, -32768), (32767, -32768), (1, 0), (0, 1), (-1, -1), (2, -3)] + [(rng.randint(-32768, 32767), rng.randint(-32768, 32767)) for _ in range(600)]     + [(rng.randint(-40, 40), rng.randint(-40, 40)) for _ in range(300)] + [(rng.randint(-3000, 3000), rng.randint(-3000, 3000)) for _ in range(NUM_ACTIVE_SC)]
fr = fr[:NUM_ACTIVE_SC]
ce_in, ce_exp = [], []
yr_a = np.array([a for a, b in fr]); yi_a = np.array([b for a, b in fr])
mr, mi, E = rfx.chest(yr_a, yi_a)
wr("cest_exp.mem", [pack_w(int(a), int(b), int(c)) for a, b, c in zip(mr, mi, E)], 10)
import phy2_fixed_ref as _pf0
wr("cest_lg.mem", [int(v) & 0xFFF for v in _pf0.chest_lg(yr_a, yi_a)], 3)
wr("cest_sum.mem", [_pf0.chest_lg_sum(yr_a, yi_a)[1]], 11)
wr("cest_tau.mem", [_pf0.timing_est(yr_a, yi_a)[0] & 0xFFFFF], 5)
# gaps: valid + {first,last} + data
seq = []
for k, (a, b) in enumerate(fr):
    while rng.random() < 0.25:
        seq.append((0, rng.getrandbits(34)))
    seq.append((1, (int(k == 0) << 33) | (int(k == NUM_ACTIVE_SC - 1) << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)))
seq += [(0, 0)] * 8
wr("cest_in.mem", [(v << 34) | w for v, w in seq], 9)
# equalizer: weights from a realistic channel + Y data
_np = np.random.default_rng(77)
H = (_np.uniform(0.2, 2.0, NUM_ACTIVE_SC) * np.exp(1j * _np.uniform(-3.14, 3.14, NUM_ACTIVE_SC)))
lts_s = rfx.lts_sign()
ylts = np.round(H * 12288 * lts_s * 0.15).astype(complex)
wmr, wmi, wE = rfx.chest(ylts.real.astype(np.int64), ylts.imag.astype(np.int64))
wr("eqw_exp.mem", [pack_w(int(a), int(b), int(c)) for a, b, c in zip(wmr, wmi, wE)], 10)
xs = [(rng.randint(-8000, 8000), rng.randint(-8000, 8000)) for _ in range(NUM_ACTIVE_SC)]
xs[0] = (32767, -32768); xs[1] = (-32768, 32767); xs[2] = (0, 0)
yd_r = np.array([a for a, b in xs]); yd_i = np.array([b for a, b in xs])
eq_r, eq_i = rfx.equalize(yd_r, yd_i, wmr, wmi, wE)
seq = []
for k, (a, b) in enumerate(xs):
    while rng.random() < 0.25:
        seq.append((0, rng.getrandbits(34)))
    seq.append((1, (int(k == 0) << 33) | (int(k == NUM_ACTIVE_SC - 1) << 32) | ((a & 0xFFFF) << 16) | (b & 0xFFFF)))
seq += [(0, 0)] * 12
wr("eq_in.mem", [(v << 34) | w for v, w in seq], 9)
wr("eq_exp.mem", [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(eq_r, eq_i)], 8)

# ---- phase tracker: frames of equalised active bins (QAM + pilots) rotated by a common phase + noise ----
_pay2 = [rng.getrandbits(8) for _ in range(2200)]
qpts, _w = tx_ref.tx_data_symbols(_pay2)
psg = rfx.pilot_sign()
thetas = [0.0, np.pi / 2, -np.pi / 2 + 0.001, np.pi - 0.001, 0.37, -2.9]
pt_in, pt_exp = [], []
_np2 = np.random.default_rng(5)
for f, th in enumerate(thetas):
    sym = np.zeros(NUM_ACTIVE_SC, complex)
    sym[rfx.DATA_S] = qpts[f % qpts.shape[0]]
    sym[rfx.PILOT_S] = psg * 12288
    sym = sym * np.exp(1j * th) + 300 * (_np2.standard_normal(NUM_ACTIVE_SC) + 1j * _np2.standard_normal(NUM_ACTIVE_SC))
    xr = np.clip(np.round(sym.real), -32768, 32767).astype(np.int64); xi = np.clip(np.round(sym.imag), -32768, 32767).astype(np.int64)
    yr, yi, ang, l1 = rfx.cpe_track_l1(xr, xi)
    for k in range(NUM_ACTIVE_SC):
        pt_in.append((int(k == 0) << 33) | (int(k == NUM_ACTIVE_SC - 1) << 32) | ((int(xr[k]) & 0xFFFF) << 16) | (int(xi[k]) & 0xFFFF))
    for k in rfx.DATA_S:
        pt_exp.append(((int(yr[k]) & 0xFFFF) << 16) | (int(yi[k]) & 0xFFFF))
    pt_exp.append(ang)       # angle marker appended after each frame's data (TB separates by position)
    pt_exp.append(l1)        # pilot L1 error
wr("cpe_in.mem", pt_in, 9)
wr("cpe_exp.mem", pt_exp, 8)
# slope mode (phase ramp over frequency = sampling clock offset): same QAM frames, per-frame slope in rad per bin
slopes_rad = [0.0, 2.0e-4, -4.0e-4, 8.0e-4, -1.2e-3, 3.4e-4]
ps_in, ps_exp = [], []
_np3 = np.random.default_rng(15)
for f, th in enumerate(thetas):
    sym = np.zeros(NUM_ACTIVE_SC, complex)
    sym[rfx.DATA_S] = qpts[f % qpts.shape[0]]
    sym[rfx.PILOT_S] = psg * 12288
    sym = sym * np.exp(1j * (th + slopes_rad[f] * rfx.FREQ_S)) + 300 * (_np3.standard_normal(NUM_ACTIVE_SC) + 1j * _np3.standard_normal(NUM_ACTIVE_SC))
    xr = np.clip(np.round(sym.real), -32768, 32767).astype(np.int64); xi = np.clip(np.round(sym.imag), -32768, 32767).astype(np.int64)
    yr, yi, ang, sbin = rfx.cpe_sfo_track(xr, xi)
    sgp = rfx.pilot_sign()
    l1 = int(np.sum(np.abs(yr[rfx.PILOT_S].astype(np.int64) - sgp * rfx.A_LTS) + np.abs(yi[rfx.PILOT_S].astype(np.int64))))
    for k in range(NUM_ACTIVE_SC):
        ps_in.append((int(k == 0) << 33) | (int(k == NUM_ACTIVE_SC - 1) << 32) | ((int(xr[k]) & 0xFFFF) << 16) | (int(xi[k]) & 0xFFFF))
    for k in rfx.DATA_S:
        ps_exp.append(((int(yr[k]) & 0xFFFF) << 16) | (int(yi[k]) & 0xFFFF))
    ps_exp += [ang, l1, int(sbin) & 0xFFFFFFFF]
wr("cps_in.mem", ps_in, 9)
wr("cps_exp.mem", ps_exp, 8)

# ---- RX decode back-end (demap -> deinterleave -> hard bits -> descramble): 3 symbols, noisy QAM points ----
_pay3 = [rng.getrandbits(8) for _ in range(3 * BYTES_PER_OFDM - 37)]
_q3, _ = tx_ref.tx_data_symbols(_pay3)
_np3 = np.random.default_rng(11)
dec_syms = []
dec_in = []
for f in range(_q3.shape[0]):
    pts = _q3[f] + 1600 * (_np3.standard_normal(NUM_DATA_SC) + 1j * _np3.standard_normal(NUM_DATA_SC))
    xr = np.clip(np.round(pts.real), -32768, 32767).astype(np.int64); xi = np.clip(np.round(pts.imag), -32768, 32767).astype(np.int64)
    dec_syms.append((xr, xi))
    dec_in += [(int(k == 0) << 33) | (int(k == NUM_DATA_SC - 1) << 32) | ((int(xr[k]) & 0xFFFF) << 16) | (int(xi[k]) & 0xFFFF) for k in range(NUM_DATA_SC)]
dec_bytes = rfx.decode_symbols(dec_syms, 3 * BYTES_PER_OFDM)
wr("dec_in.mem", dec_in, 9)
wr("dec_exp.mem", dec_bytes, 2)
print("decode back-end byte errors vs payload (noise 1600):", sum(a != b for a, b in zip(dec_bytes, _pay3)), "of", len(_pay3))

# ---- full RX system test: two packets back to back (1100 bytes = 2 symbols each), different CFO / channel ----
SYS_NSYMS = 2
pay_a = [rng.getrandbits(8) for _ in range(SYS_NSYMS * BYTES_PER_OFDM)]
pay_b = [rng.getrandbits(8) for _ in range(SYS_NSYMS * BYTES_PER_OFDM)]
xa = np.array([complex(a, b) for a, b in tx_ref.tx_frame(pay_a)]); xb = np.array([complex(a, b) for a, b in tx_ref.tx_frame(pay_b)])
seg_a = channel_ref.apply_channel(xa, snr_db=35, cfo_hz=9000.0, paths=((0, 1),), lead=1200, trail=9000, seed=21)
seg_b = channel_ref.apply_channel(xb, snr_db=30, cfo_hz=-7000.0, paths=((0, 1), (9, 0.4j)), lead=0, trail=3000, seed=22)
i_a, q_a = sync_test.adc(np.concatenate([seg_a, seg_b]))
wr("rxs_in.mem", [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(i_a, q_a)], 8)
wr("rxs_pay.mem", pay_a + pay_b, 2)
_di = np.array(rb.dc_remove(i_a, 16)); _dq = np.array(rb.dc_remove(q_a, 16))
_ev = sync_ref.detect_events(_di, _dq, hold=9000)
def _py_evm(di, dq, e):
    """python mirror of the RX packet path: sum of the pilot L1 errors over the data symbols (RTL differs by a few NCO samples)."""
    inc = sync_ref.cfo_inc(e["p_re"], e["p_im"])
    w0 = e["n_best"] + 104
    n0 = min(e["n_decl"] + 4, w0)
    yi, yq = rb.nco_mix(di[n0:], dq[n0:], inc)
    tot = 0
    for k in range(1, SYS_NSYMS + 1):
        a = w0 - n0 + k * SYMBOL_LEN
        yr, yi2 = rfx.select_active(*rfx.rx_fft(yi[w0 - n0:w0 - n0 + FFT_SIZE], yq[w0 - n0:w0 - n0 + FFT_SIZE]))
        mr, mi, E = rfx.chest(yr, yi2)
        dr, di_ = rfx.select_active(*rfx.rx_fft(yi[a:a + FFT_SIZE], yq[a:a + FFT_SIZE]))
        xr, xi = rfx.equalize(dr, di_, mr, mi, E)
        tot += rfx.cpe_track_l1(xr, xi)[3]
    return tot

with open(os.path.join(OUT, "rxs_ev.mem"), "w") as f:
    for e in _ev:
        f.write(("%08x %08x %08x %08x" % (e["n_best"], sync_ref.cfo_inc(e["p_re"], e["p_im"]), sync_ref.rssi_code(e["r_best"]), _py_evm(_di, _dq, e))) + chr(10))
# ---- coded variant of the system stream: LDPC frames, same channel structure, B at a lower SNR so that LDPC iterates ----
_pc = [[rng.getrandbits(8) for _ in range(2 * 450)] for _ in range(2)]
_xc = [np.array([complex(a, b) for a, b in tx_ref.tx_frame(pp, code="ldpc")]) for pp in _pc]
_sga = channel_ref.apply_channel(_xc[0], snr_db=33, cfo_hz=9000.0, paths=((0, 1),), lead=1200, trail=9000, seed=31)
_sgb = channel_ref.apply_channel(_xc[1], snr_db=22, cfo_hz=-7000.0, paths=((0, 1), (9, 0.4j)), lead=0, trail=3000, seed=32)
_ic, _qc = sync_test.adc(np.concatenate([_sga, _sgb]))
wr("rxc_in.mem", [((int(a) & 0xFFFF) << 16) | (int(b) & 0xFFFF) for a, b in zip(_ic, _qc)], 8)
wr("rxc_pay.mem", _pc[0] + _pc[1], 2)
_dic = np.array(rb.dc_remove(_ic, 16)); _dqc = np.array(rb.dc_remove(_qc, 16))
_evc = sync_ref.detect_events(_dic, _dqc, hold=9000)
with open(os.path.join(OUT, "rxc_ev.mem"), "w") as f:
    for e in _evc:
        f.write(("%08x %08x %08x %08x" % (e["n_best"], sync_ref.cfo_inc(e["p_re"], e["p_im"]), sync_ref.rssi_code(e["r_best"]), 0)) + chr(10))
print("coded rx system stream", len(_ic), "samples; events", [(e["n_decl"], e["n_best"]) for e in _evc])
print("rx system stream", len(i_a), "samples; events", [(e["n_decl"], e["n_best"]) for e in _ev])
print("OK vectors in", OUT)

# ---- LDPC decoder (fixed-point, bit-exact vs ldpc_fixed_ref): several codewords back to back ----
import ldpc_ref, ldpc_fixed_ref
_rg = np.random.default_rng(77)
_rate = ldpc_ref.K / ldpc_ref.N
_cws = []
_snrs = [6.0, 4.2, 3.7, 3.4, 2.0, 5.0, 3.8, 9.0]        # Eb/N0 [dB]: clean ... marginal ... failing
_info = _rg.integers(0, 2, (len(_snrs), ldpc_ref.K), dtype=np.uint8)
_cw = ldpc_ref.encode(_info)
_llrq = []
for _i, _s in enumerate(_snrs):
    _sig = np.sqrt(1 / (2 * _rate * 10 ** (_s / 10)))
    _y = (1 - 2.0 * _cw[_i]) + _sig * _rg.standard_normal(ldpc_ref.N)
    _llrq.append(ldpc_fixed_ref.quant_llr(2 * _y / _sig ** 2, 1.5))
_llrq.append(np.zeros(ldpc_ref.N, np.int64))              # all-zero LLRs
_llrq.append(np.clip(np.rint(_rg.standard_normal(ldpc_ref.N) * 6), -31, 31).astype(np.int64))    # noise only
_llrq = np.array(_llrq)
LDP_MAXIT = 10
_hard, _its, _done = ldpc_fixed_ref.decode(_llrq, LDP_MAXIT)
_inw, _exp = [], []
for _i in range(len(_llrq)):
    for _w in range(ldpc_ref.N // 4):
        _inw.append(sum((int(_llrq[_i][4 * _w + _j]) & 0x3F) << (6 * (3 - _j)) for _j in range(4)))
    _by = np.packbits(_hard[_i][:ldpc_ref.K])
    _exp += [int(b) for b in _by] + [(int(_done[_i]) << 8) | int(_its[_i])]
wr("ldp_in.mem", _inw, 6)
wr("ldp_exp.mem", _exp, 3)
print("ldpc decoder vectors:", len(_llrq), "codewords, iterations", _its.tolist(), "done", _done.astype(int).tolist())

# ---- LDPC encoder: 4 codewords (2 OFDM symbols: 2 x 540 nibbles + 20 filler nibbles each) ----
_re = np.random.default_rng(88)
_einfo = _re.integers(0, 2, (4, ldpc_ref.K), dtype=np.uint8)
_ecw = ldpc_ref.encode(_einfo)
_ebytes, _enib = [], []
for _i in range(4):
    _ebytes += [int(b) for b in np.packbits(_einfo[_i])]
    _bits = _ecw[_i].reshape(-1, 4)
    _enib += [int(a) << 3 | int(b) << 2 | int(c) << 1 | int(d) for a, b, c, d in _bits]
    if _i % 2 == 1:
        _enib += [5] * 20
wr("lpe_in.mem", _ebytes, 2)
wr("lpe_exp.mem", _enib, 1)
print("ldpc encoder vectors:", len(_ebytes), "bytes ->", len(_enib), "nibbles")

# ---- soft LLR demapper (phy_llr_demap): 3 symbols of 1100 bins against one parameter set ----
import phy2_fixed_ref as pf
_rs = np.random.default_rng(99)
_nb = 1100
_T = _rs.integers(0, 8193, _nb); _T[::7] = 8192
_gm = _rs.integers(32, 64, _nb)
_ge = _rs.integers(-8, 32, _nb)
_prm = [(int(_T[k]) << 13) | (int(_gm[k]) << 7) | (int(_ge[k]) & 0x7F) for k in range(_nb)]
wr("llr_prm.mem", _prm, 8)
_sx, _se = [], []
for _s in range(3):
    _xr = _rs.integers(-30000, 30000, _nb); _xi = _rs.integers(-30000, 30000, _nb)
    _xr[::5] = _rs.integers(-300, 300, len(_xr[::5])); _xi[::6] = _rs.integers(-300, 300, len(_xi[::6]))
    _llr = pf.demap_soft(_xr, _xi, _T, _gm, _ge)
    for _k in range(_nb):
        _sx.append((int(_xr[_k]) & 0xFFFF) << 16 | (int(_xi[_k]) & 0xFFFF))
        _se.append(sum((int(_llr[_k][_j]) & 0x3F) << (6 * (3 - _j)) for _j in range(4)))
wr("llr_in.mem", _sx, 8)
wr("llr_exp.mem", _se, 6)
print("llr demap vectors:", len(_sx))

# ---- noise estimator: 3 FFT frames (first and third measured), guard-bin energy -> log code ----
_rn = np.random.default_rng(55)
_nf, _nexp = [], []
for _f in range(3):
    _sc = [300, 20000, 40][_f]
    _yr = np.clip(np.rint(_rn.standard_normal(FFT_SIZE) * _sc), -32768, 32767).astype(np.int64)
    _yi = np.clip(np.rint(_rn.standard_normal(FFT_SIZE) * _sc), -32768, 32767).astype(np.int64)
    if _f == 1:
        _yr[:] = 0; _yi[:] = 0
    for _b in range(FFT_SIZE):
        _nf.append((int(_yr[_b]) & 0xFFFF) << 16 | (int(_yi[_b]) & 0xFFFF))
    if _f != 1:
        _code, _S = pf.noise_code(_yr, _yi)
        _nexp.append((_code & 0x1FFF, _S))
wr("nse_in.mem", _nf, 8)
wr("nse_exp.mem", [(c << 41) | s for c, s in _nexp], 14)
print("noise est vectors:", len(_nf), [(c, s) for c, s in _nexp])

# ---- MMSE post engine: weights / log codes in, rewritten weights + data-bin parameters out (MMSE and ZF runs) ----
_rp = np.random.default_rng(66)
_pw = [(int(_rp.integers(-32767, 32768)), int(_rp.integers(-32767, 32768)), int(_rp.integers(-10, 35))) for _ in range(NUM_ACTIVE_SC)]
_plg = _rp.integers(-300, 1000, NUM_ACTIVE_SC)
_plg[::37] = -1000
_plg[5::41] = 1023
_mr = np.array([a for a, b, c in _pw]); _mi = np.array([b for a, b, c in _pw]); _E = np.array([c for a, b, c in _pw])
wr("eng_w.mem", [pack_w(a, b, c) for a, b, c in _pw], 10)
wr("eng_lg.mem", [int(v) & 0xFFF for v in _plg], 3)
_nus = [250, -60]
wr("eng_nu.mem", [v & 0x1FFF for v in _nus], 4)
_res = {}
for _mode in (1, 0):
    _mr2, _mi2, _T, _gm, _ge = pf.post_engine(_mr, _mi, _E, _plg, _nus[0] if _mode else _nus[1], bool(_mode))
    _ds = rfx.DATA_S
    _res[_mode] = ([pack_w(int(a), int(b), int(c)) for a, b, c in zip(_mr2, _mi2, _E)],
                   [(int(_T[k]) << 13) | (int(_gm[k]) << 7) | (int(_ge[k]) & 0x7F) for k in _ds])
wr("eng_exp_w.mem", _res[1][0], 10)
wr("eng_exp_p1.mem", _res[1][1], 8)
wr("eng_exp_p0.mem", _res[0][1], 8)
_qs = []
_sig_sums = [int(_rp.integers(1 << 28, 1 << 40)), int(_rp.integers(1 << 20, 1 << 30))]
for _mode, _nu_ in ((1, _nus[0]), (0, _nus[1])):
    _qs.append(pf.quality_codes(_plg, _nu_, _sig_sums[0 if _mode else 1]))
wr("eng_q.mem", [(_sig_sums[0] << 0), (_sig_sums[1] << 0)], 11)
wr("eng_qexp.mem", [((a & 0x1FFF) << 24) | ((m & 0x1FFF) << 11) | (b & 0x7FF) for (a, m, b) in _qs], 10)
print("mmse post vectors ok", _qs)

# ---- coded RX back-end (phy_rx_decode_ldpc): 2-symbol packet (900 bytes) through the real chain model on a 2-path channel ----
import phy2_ref as _p2
import phy2_fixed_test as _p2t
import phy2_test as _p2s
_rb = np.random.default_rng(404)
_p2s.rng = _rb
_nsy = 2
_Hc = _p2s.chan("2path")
_pay_b = bytes(_rb.integers(0, 256, _p2.bytes_per_sym("ldpc") * _nsy, dtype=np.uint8))
_wds = _p2.tx_words(_pay_b, _nsy, "ldpc")
_sg2 = np.mean(np.abs(_Hc) ** 2) * _p2.P_DATA / 10 ** (18.5 / 10)
_yl, _ys = _p2s.make_y(_wds, _Hc, _sg2, _nsy)
_ylq, _ysq = _p2t.int_y(_yl, _ys)
_llr_b, _dg = pf.receive_symbols(_ylq, _ysq, True)
_bytes_b, _its_b, _done_b = pf.decode_llr(_llr_b, _nsy, len(_pay_b), 10)
print("coded back-end vector: payload match", _bytes_b == _pay_b, "iterations", _its_b.tolist())
_xin = []
for _s in range(_nsy):
    _xr, _xi = _dg["eq"][_s]
    for _k in range(1100):
        _xin.append((int(_xr[_k]) & 0xFFFF) << 16 | (int(_xi[_k]) & 0xFFFF))
wr("cdb_in.mem", _xin, 8)
wr("cdb_prm.mem", [(int(_dg["T"][k]) << 13) | (int(_dg["gm"][k]) << 7) | (int(_dg["ge"][k]) & 0x7F) for k in range(1100)], 8)
wr("cdb_exp.mem", [int(b) for b in _bytes_b], 2)
wr("cdb_stat.mem", [int((~_done_b).sum()), int(_its_b.max()), int(_its_b.sum())], 4)
