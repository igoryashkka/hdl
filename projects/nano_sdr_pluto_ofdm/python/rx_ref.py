"""Floating-point reference receiver (algorithm validation, DSP-first step before fixed-point/RTL).
Chain: Schmidl-Cox detection + fractional CFO -> CFO correction -> LTS cross-correlation fine timing ->
       integer CFO (sync-symbol spectrum) -> FFT -> LS channel estimate (LTS) -> pilot phase tracking ->
       one-tap equalizer -> soft/hard demap -> deinterleave -> descramble.
Frame layout (see tx_ref.tx_frame): [sync: CP+body][LTS: CP+body][data symbols: CP+body each], body = FFT_SIZE samples."""
import numpy as np
from phy_params import *
import ofdm_ref

N, CP, SYM = FFT_SIZE, CP_LEN, FFT_SIZE + CP_LEN
L = N // 2

ACTIVE_BINS = np.array([b for b in range(N) if ofdm_ref.s_of_bin(b) >= 0])
PILOT_BINS = np.array([b for b in range(N) if ofdm_ref.s_of_bin(b) >= 0 and ofdm_ref.is_pilot_slot(ofdm_ref.s_of_bin(b))])
DATA_BINS = np.array([b for b in range(N) if ofdm_ref.s_of_bin(b) >= 0 and not ofdm_ref.is_pilot_slot(ofdm_ref.s_of_bin(b))])
LTS_F = np.array([complex(a, b) for a, b in ofdm_ref.preamble(1)])
SYNC_F = np.array([complex(a, b) for a, b in ofdm_ref.preamble(0)])
LTS_T = np.fft.ifft(LTS_F)          # time-domain template (unscaled, only the shape matters)
PILOT_VAL = np.array([complex(a, b) for a, b in ofdm_ref.insert_pilots(ofdm_ref.map_bins([(0, 0)] * NUM_DATA_SC))])[PILOT_BINS]


def sc_metric(r):
    """Schmidl-Cox timing metric M(d) = |P(d)|^2 / R(d)^2 and P(d) for all d (vectorised sliding sums)."""
    prod = np.conj(r[:-L]) * r[L:]
    cs = np.concatenate([[0], np.cumsum(prod)])
    P = cs[L:] - cs[:-L]                       # P[d] = sum_{m<L} conj(r[d+m]) r[d+m+L]
    en = np.abs(r[L:]) ** 2
    ce = np.concatenate([[0], np.cumsum(en)])
    R = ce[L:] - ce[:-L]
    n = min(len(P), len(R))
    P, R = P[:n], R[:n]
    return np.abs(P) ** 2 / np.maximum(R, 1e-12) ** 2, P


def detect(r, thresh=0.5):
    """Coarse packet detection + timing: first crossing of the Schmidl-Cox metric, then the plateau (CP long, M ~ max)
    is located and its centre gives the sync-symbol start estimate s0 = centre - CP/2. Returns (s0, P at the centre)."""
    M, P = sc_metric(r)
    idx = np.nonzero(M > thresh)[0]
    if len(idx) == 0:
        return None, P
    d0 = idx[0]
    seg = M[d0: d0 + 2 * SYM]
    top = np.nonzero(seg >= 0.9 * seg.max())[0]
    c = d0 + int(np.median(top))
    return c - CP // 2, P[c]


def frac_cfo(P_at_d):
    """Fractional CFO in subcarrier spacings: phase(P)=pi*eps."""
    return np.angle(P_at_d) / np.pi


def correct_cfo(r, eps, start=0):
    n = np.arange(len(r)) - start
    return r * np.exp(-2j * np.pi * eps * n / N)


def fine_timing(r, s0, search=48):
    """Locate the LTS body start by cross-correlation with the known template around the expected position."""
    exp = s0 + SYM + CP
    best, bi = -1, exp
    for s in range(exp - search, exp + search):
        if s < 0 or s + N > len(r):
            continue
        c = np.abs(np.vdot(LTS_T, r[s:s + N]))
        if c > best:
            best, bi = c, s
    return bi, best


def fft_sym(r, start):
    return np.fft.fft(r[start:start + N])


def int_cfo(r, win_start, max_shift=16):
    """Integer CFO (subcarriers) from the sync symbol: differential correlation of adjacent even bins with the known
    sequence, insensitive to the linear phase caused by a timing offset inside the CP."""
    X = fft_sym(r, win_start)
    ev = ACTIVE_BINS[(ACTIVE_BINS % 2 == 0)]
    ev = ev[np.isin(ev + 2, ACTIVE_BINS)]
    ref = np.conj(SYNC_F[ev]) * SYNC_F[ev + 2]
    best, bm = -1, 0
    for m in range(-max_shift, max_shift + 1):
        k = (ev + m) % N
        c = np.abs(np.sum(ref * X[k] * np.conj(X[(k + 2) % N])))
        if c > best:
            best, bm = c, m
    return bm


def receive(r, n_data_syms, back_off=48, thresh=0.5, max_int=16, equalize=True, track=True, fine=False):
    out = {"ok": False}
    s0, Pc = detect(r, thresh)
    if s0 is None:
        return out
    eps = frac_cfo(Pc)
    r1 = correct_cfo(r, eps)
    m = int_cfo(r1, s0 + CP // 2, max_int)                 # FFT window inside the sync CP/body (any start in the CP works)
    r2 = correct_cfo(r1, m) if m else r1
    # RTL architecture: coarse timing only. The FFT window is placed BACK_OFF samples early (inside the CP, ISI-free for
    # delay spread < CP - BACK_OFF - coarse error); the residual offset is a linear phase absorbed by the channel estimate.
    lts_body = fine_timing(r2, s0)[0] if fine else s0 + SYM + CP
    w = lts_body - back_off                                # FFT window start for the LTS (inside the CP)
    Y1 = fft_sym(r2, w)
    H = np.zeros(N, complex)
    H[ACTIVE_BINS] = Y1[ACTIVE_BINS] / LTS_F[ACTIVE_BINS]
    syms = []
    for k in range(n_data_syms):
        s = w + SYM * (1 + k)
        Y = fft_sym(r2, s)
        X = np.zeros(N, complex)
        X[ACTIVE_BINS] = Y[ACTIVE_BINS] / H[ACTIVE_BINS] if equalize else Y[ACTIVE_BINS]
        if track:
            cpe = np.angle(np.sum(X[PILOT_BINS] * np.conj(PILOT_VAL)))     # common phase error from the pilots
            X *= np.exp(-1j * cpe)
        syms.append(X[DATA_BINS])
    out.update(ok=True, s0=s0, eps=eps, int_cfo=m, cfo_hz=(eps + m) * SUBCARRIER_HZ, lts_body=lts_body, H=H, syms=np.array(syms))
    return out
