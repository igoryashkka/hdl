"""QC-LDPC code (rate 5/6, N = 2160, K = 1800, Z = 60) + layered normalised min-sum decoder -- floating-point reference.

Base matrix 6 x 36: 30 information columns (weight 3) + 6 parity columns in the 802.11n style (first parity column with three
entries x, 0, x and a dual diagonal), so encoding is a plain accumulation without matrix inversion. The shifts of the
information part are chosen by a seeded search that avoids all length-4 cycles of the Tanner graph (QC condition below) and then
by a short Monte-Carlo comparison (see `search_code`). `H_BASE` is stored explicitly once found so RTL, Python and the
tests all use the same code.

Conventions: bit 0 <-> LLR > 0 (LLR = ln P(0)/P(1)); a codeword is [info(1800) | parity(360)] block-wise: block j = 60 bits.
Circulant P^s maps vector v -> np.roll(v, -s) (row r of the block row checks bit (r + s) mod Z of the block column).
"""
from __future__ import annotations

import numpy as np

Z = 60
MB = 6
NB = 36
KB = NB - MB
N = Z * NB          # 2160 coded bits
K = Z * KB          # 1800 information bits

# H_BASE[i][j] = shift (0..Z-1) or -1 (no entry); filled by _build() with the code chosen by search_code().
H_BASE: np.ndarray | None = None


def _qc_ok(base: np.ndarray) -> bool:
    """No 4-cycles: for every pair of block rows the shift differences over the shared columns are all distinct."""
    m = base.shape[0]
    for i in range(m):
        for j in range(i + 1, m):
            d = [(int(base[i, c]) - int(base[j, c])) % Z for c in range(base.shape[1]) if base[i, c] >= 0 and base[j, c] >= 0]
            if len(set(d)) != len(d):
                return False
    return True


def build_base(seed: int = 1, tries: int = 2000, mb: int = MB, info_deg=None) -> np.ndarray:
    """mb block rows (rate (NB-mb)/NB); info_deg[c] = weight of information column c (default 3 for all)."""
    kb = NB - mb
    info_deg = [3] * kb if info_deg is None else list(info_deg)
    rng = np.random.default_rng(seed)
    for _ in range(tries):
        base = -np.ones((mb, NB), dtype=np.int64)
        # information part: columns with their weight, rows balanced
        load = np.zeros(mb, int)
        for c in range(kb):
            order = np.argsort(load + rng.random(mb) * 0.9)
            rows = order[:info_deg[c]]
            load[rows] += 1
            for r in rows:
                base[r, c] = rng.integers(0, Z)
        # parity part (802.11n style): column kb has entries in row 0 (shift a), row mb//2 (shift 0), row mb-1 (shift a)
        a = int(rng.integers(1, Z))
        base[0, kb] = a
        base[mb // 2, kb] = 0
        base[mb - 1, kb] = a
        for k in range(1, mb):             # dual diagonal: column kb+k has entries in rows k-1 and k, shift 0
            base[k - 1, kb + k] = 0
            base[k, kb + k] = 0
        if _qc_ok(base):
            return base
    raise RuntimeError("no 4-cycle-free code found")


def expand(base: np.ndarray) -> np.ndarray:
    mb = base.shape[0]
    H = np.zeros((mb * Z, NB * Z), dtype=np.uint8)
    for i in range(mb):
        for j in range(NB):
            s = base[i, j]
            if s >= 0:
                for r in range(Z):
                    H[i * Z + r, j * Z + (r + s) % Z] = 1
    return H


def encode(info: np.ndarray, base: np.ndarray | None = None) -> np.ndarray:
    """info: (B, K) bits -> (B, N) codewords [info | parity]."""
    base = H_BASE if base is None else base
    MB = base.shape[0]
    KB = NB - MB
    info = np.atleast_2d(info).astype(np.uint8)
    B = info.shape[0]
    u = info.reshape(B, KB, Z)
    lam = np.zeros((B, MB, Z), dtype=np.uint8)           # lambda_i = sum_j P^s(i,j) u_j
    for i in range(MB):
        for j in range(KB):
            s = base[i, j]
            if s >= 0:
                lam[:, i] ^= np.roll(u[:, j], -s, axis=1)
    p = np.zeros((B, MB, Z), dtype=np.uint8)
    p[:, 0] = np.bitwise_xor.reduce(lam, axis=1)         # the two shifted copies of p0 cancel in the sum of all rows
    a = int(base[0, KB])
    # row 0: lam0 + P^a p0 + p1 = 0
    p[:, 1] = lam[:, 0] ^ np.roll(p[:, 0], -a, axis=1)
    for i in range(1, MB - 1):                           # row i: lam_i + [p0 if i == MB//2] + p_i + p_{i+1} = 0
        p[:, i + 1] = lam[:, i] ^ p[:, i]
        if i == MB // 2:
            p[:, i + 1] ^= p[:, 0]
    cw = np.concatenate([u, p], axis=1).reshape(B, N)
    return cw


def syndrome_ok(cw: np.ndarray, base: np.ndarray | None = None) -> np.ndarray:
    base = H_BASE if base is None else base
    MB = base.shape[0]
    cw = np.atleast_2d(cw).astype(np.uint8)
    B = cw.shape[0]
    x = cw.reshape(B, NB, Z)
    ok = np.ones(B, bool)
    for i in range(MB):
        s = np.zeros((B, Z), dtype=np.uint8)
        for j in range(NB):
            sh = base[i, j]
            if sh >= 0:
                s ^= np.roll(x[:, j], -sh, axis=1)
        ok &= ~s.any(axis=1)
    return ok


def decode(llr: np.ndarray, iters: int = 20, alpha: float = 0.75, base: np.ndarray | None = None, early_stop: bool = True):
    """Layered normalised min-sum. llr: (B, N) channel LLRs (positive = bit 0). Returns (hard bits (B, N), iterations used (B,), ok (B,))."""
    base = H_BASE if base is None else base
    MB = base.shape[0]
    llr = np.atleast_2d(llr).astype(np.float64)
    B = llr.shape[0]
    L = llr.reshape(B, NB, Z).copy()
    ent = [[(j, int(base[i, j])) for j in range(NB) if base[i, j] >= 0] for i in range(MB)]
    R = [np.zeros((B, len(ent[i]), Z)) for i in range(MB)]          # check-to-variable messages per layer
    used = np.full(B, iters)
    done = np.zeros(B, bool)
    for it in range(1, iters + 1):
        for i in range(MB):
            e = ent[i]
            Q = np.stack([np.roll(L[:, j], -s, axis=1) for j, s in e], axis=1) - R[i]     # (B, deg, Z)
            sgn = np.where(Q < 0, -1.0, 1.0)
            tot = sgn.prod(axis=1, keepdims=True)
            mag = np.abs(Q)
            idx = np.argmin(mag, axis=1)
            m1 = np.take_along_axis(mag, idx[:, None, :], axis=1)
            mag2 = mag.copy()
            np.put_along_axis(mag2, idx[:, None, :], np.inf, axis=1)
            m2 = mag2.min(axis=1, keepdims=True)
            use = np.where(np.arange(len(e))[None, :, None] == idx[:, None, :], m2, m1)
            Rn = alpha * use * tot * sgn
            for k, (j, s) in enumerate(e):
                L[:, j] = np.roll(Q[:, k] + Rn[:, k], s, axis=1)
            R[i] = Rn
        hard = (L.reshape(B, N) < 0).astype(np.uint8)
        if early_stop:
            ok = syndrome_ok(hard, base)
            newly = ok & ~done
            used[newly] = it
            done |= ok
            if done.all():
                break
    hard = (L.reshape(B, N) < 0).astype(np.uint8)
    return hard, used, syndrome_ok(hard, base)


# ---------------------------------------------------------------- code selection
def search_code(seeds=range(1, 9), snr_db=3.6, frames=60, seed=0, mb: int = MB, info_deg=None, iters=25) -> tuple[int, np.ndarray]:
    """BPSK/AWGN Monte-Carlo comparison of candidate codes (frame errors at Eb/N0 = snr_db); returns (best seed, base)."""
    best = None
    rng = np.random.default_rng(seed)
    k = (NB - mb) * Z
    rate = k / N
    sigma = np.sqrt(1.0 / (2 * rate * 10 ** (snr_db / 10)))
    for s in seeds:
        base = build_base(s, mb=mb, info_deg=info_deg)
        info = rng.integers(0, 2, (frames, k), dtype=np.uint8)
        cw = encode(info, base)
        x = 1 - 2.0 * cw
        y = x + sigma * rng.standard_normal(x.shape)
        _, _, ok = decode(2 * y / sigma ** 2, iters, base=base)
        fer = float((~ok).mean())
        if best is None or fer < best[0]:
            best = (fer, s, base)
    return best[1], best[2]


def _init():
    global H_BASE, H_BASE12
    H_BASE = build_base(_CHOSEN_SEED)
    H_BASE12 = build_base(_SEED12, mb=MB12, info_deg=INFO_DEG12)


_CHOSEN_SEED = 1
# rate 1/2 (MAX RANGE): 18 x 36 base, 18 information columns with an irregular weight profile (chosen by Monte-Carlo, see _ldpc_cmp.py)
MB12 = 18
KB12 = NB - MB12
K12 = Z * KB12                      # 1080 information bits per codeword
INFO_DEG12 = [8] * 2 + [5] * 8 + [3] * 8
_SEED12 = 5
H_BASE12: np.ndarray | None = None
_init()

CODES = {"r56": H_BASE, "r12": H_BASE12}       # rate 5/6 (MAX RATE) and rate 1/2 (MAX RANGE), same N = 2160 and Z = 60


def code_info_bits(base: np.ndarray) -> int:
    return (NB - base.shape[0]) * Z
