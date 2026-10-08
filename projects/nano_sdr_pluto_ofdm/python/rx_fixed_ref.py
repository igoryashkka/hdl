"""Fixed-point RX chain after the synchroniser (golden models, each function is the reference of one RTL block).
 window samples (post NCO, 16-bit) -> rx_fft -> select_active -> chest -> equalize -> cpe_track -> demap/deinterleave ->
 descramble.  All arithmetic is integer; rounding is round-half-up (+half, floor shift); saturation to 16 bit where noted."""
import numpy as np
import fft_ref, ofdm_ref, qam_ref, interleaver_ref, scrambler_ref, sync_ref, rx_blocks_ref
from phy_params import *

N_LOG = FFT_SIZE.bit_length() - 1
RX_SHIFT_MASK = 0x00F          # 4 divide-by-2 stages (see STATUS.md RX scaling)
A_LTS = PILOT_AMP              # |LTS| and |pilot| amplitude


def sat16(v):
    return np.clip(v, -32768, 32767)


# ------------------------------------------------------------------ FFT (natural order output, saturated to 16 bit)
def rx_fft(win_i, win_q, mask=RX_SHIFT_MASK, n_log=N_LOG):
    yr, yi = fft_ref.fft_fixed(win_i, win_q, n_log, 18, mask)
    yr, yi = fft_ref.natural(yr, yi, n_log)
    return sat16(yr), sat16(yi)


# ------------------------------------------------------------------ active-bin selection (stream order, 1200 bins)
ACTIVE = np.array([b for b in range(FFT_SIZE) if ofdm_ref.s_of_bin(b) >= 0])
PILOT_S = np.array([s for s in range(NUM_ACTIVE_SC) if ofdm_ref.is_pilot_slot(s)])
DATA_S = np.array([s for s in range(NUM_ACTIVE_SC) if not ofdm_ref.is_pilot_slot(s)])


def select_active(yr, yi):
    return yr[ACTIVE], yi[ACTIVE]


def lts_sign():
    """+1 / -1 per active stream index (LTS BPSK sign): bit 1 -> -A."""
    bits = ofdm_ref.lfsr_bits(LTS_SEED, NUM_ACTIVE_SC)
    return np.array([-1 if b else 1 for b in bits], dtype=np.int64)


def pilot_sign():
    bits = ofdm_ref.lfsr_bits(PILOT_SEED, NUM_PILOTS)
    return np.array([-1 if b else 1 for b in bits], dtype=np.int64)


# ------------------------------------------------------------------ channel estimate -> equalizer weight (mantissa, exponent)
REC_LUT = np.array([int(np.floor(65536.0 / (1.0 + (i + 0.5) / 256.0) + 0.5)) for i in range(256)], dtype=np.int64)   # 0.16, in (2^15, 2^16)


def recip17(M):
    """M: 17-bit [2^16, 2^17).  returns y ~ 2^32/M in (2^15, 2^16] (one Newton iteration on a 256-entry table)."""
    y0 = REC_LUT[(M >> 8) & 0xFF]
    t = (M * y0) >> 16                         # ~ 2^16 (1.16)
    e = (1 << 17) - t                          # 2 - t  (2.16, up to 18 bit)
    return (y0 * e + (1 << 15)) >> 16


def chest_one(yr, yi, sg):
    """G = Y*sg (conj-free).  w = A*conj(G)/|G|^2 = mant * 2^-E.  Returns (mr, mi, E, ok)."""
    gr, gi = int(yr) * int(sg), int(yi) * int(sg)
    gr, gi = max(-32767, min(32767, gr)), max(-32767, min(32767, gi))      # negation saturates
    m = int(gr * gr + gi * gi)
    if m == 0:
        return 0, 0, 0
    p = m.bit_length() - 1
    s = p - 16
    M = (m >> s) if s >= 0 else (m << -s)
    r = int(recip17(M))
    pr = gr * 3 * r                              # A*conj(G)*rec / 2^(20+s) , A = 3*4096 -> shift 12 into the exponent
    pi_ = -gi * 3 * r
    mx = max(abs(pr), abs(pi_))
    sh1 = max(0, int(mx).bit_length() - 15)
    mr = max(-32767, min(32767, (pr + ((1 << sh1) >> 1)) >> sh1))
    mi = max(-32767, min(32767, (pi_ + ((1 << sh1) >> 1)) >> sh1))
    E = 20 + s - sh1                             # w = (mr + j*mi) * 2^-E   (A = 3*2^12 already folded into the 3 and the shift 20)
    return int(mr), int(mi), int(E)


def chest(yr, yi):
    sg = lts_sign()
    out = [chest_one(a, b, s) for a, b, s in zip(yr, yi, sg)]
    return (np.array([o[0] for o in out]), np.array([o[1] for o in out]), np.array([o[2] for o in out]))


# ------------------------------------------------------------------ equalizer: X = Y * w (round-half-up shift by E)
def equalize(yr, yi, mr, mi, E):
    pr = yr.astype(np.int64) * mr - yi.astype(np.int64) * mi
    pi_ = yr.astype(np.int64) * mi + yi.astype(np.int64) * mr
    xr, xi = np.zeros(len(yr), np.int64), np.zeros(len(yr), np.int64)
    for k in range(len(yr)):
        e = int(E[k])
        if e > 0:
            xr[k] = (int(pr[k]) + (1 << (e - 1))) >> e
            xi[k] = (int(pi_[k]) + (1 << (e - 1))) >> e
        else:
            xr[k] = int(pr[k]) << (-e)
            xi[k] = int(pi_[k]) << (-e)
    return sat16(xr), sat16(xi)


# ------------------------------------------------------------------ common phase error tracking (pilots)
def cpe_track(xr, xi):
    """xr, xi: equalised active-bin symbols (1200).  acc = sum_p X_p * sgn_p ; theta = angle(acc) ;  X *= exp(-j*theta)."""
    sg = pilot_sign()
    ar = int(np.sum(xr[PILOT_S] * sg))
    ai = int(np.sum(xi[PILOT_S] * sg))
    ang = sync_ref.cordic_vec(*_norm17(ar, ai))
    c, s = rx_blocks_ref.nco_cs(np.array([(-ang) & 0xFFFFFFFF]))
    c, s = int(c[0]), int(s[0])
    yr = sat16((xr * c - xi * s + 16384) >> 15)
    yi = sat16((xr * s + xi * c + 16384) >> 15)
    return yr, yi, ang


# ------------------------------------------------------------------ common phase + SFO slope tracking (pilots)
import math as _math
# frequency index of the stream slot s: +1..+600 for s < 600, -600..-1 for s >= 600 (stream order = FFT bin order of the active bins)
FREQ_S = np.array([(sl + 1) if sl < NUM_ACTIVE_SC // 2 else (sl - NUM_ACTIVE_SC) for sl in range(NUM_ACTIVE_SC)], dtype=np.int64)
FREQ_P = FREQ_S[PILOT_S]
SFO_SUMF2 = int(np.sum(FREQ_P * FREQ_P))
SFO_KB_Q16 = int(round(2 ** 32 / (2 * _math.pi * A_LTS * SFO_SUMF2) * 65536 * 16))     # x16: the sum M is divided by 16 (scaling) before the product


def cpe_sfo_track(xr, xi):
    """Like cpe_track() but also fits the phase slope across frequency over the pilots (sampling frequency offset / drift of the timing):
       theta = angle(sum z_p), z_p = X_p * sigma_p ;  M = sum f_p z_p (f_p = frequency index of the pilot) ;
       s = Im(M e^{-j theta}) / (A sum f^2) (rad per bin) ; every data/pilot bin with frequency index f is rotated by exp(-j (theta + s f))
       (32 bit phase accumulator, 12 bit sin/cos table).  Returns (yr, yi, ang, s_units) with s in 2^32 = 2 pi units per bin.
       Golden for phy_phase_tracker (slope mode)."""
    sg = pilot_sign()
    zr = xr[PILOT_S] * sg
    zi = xi[PILOT_S] * sg
    ar, ai = int(np.sum(zr)), int(np.sum(zi))
    ang = sync_ref.cordic_vec(*_norm17(ar, ai))
    c, s = rx_blocks_ref.nco_cs(np.array([(-ang) & 0xFFFFFFFF]))
    c, s = int(c[0]), int(s[0])
    mr, mi = int(np.sum(FREQ_P * zr)), int(np.sum(FREQ_P * zi))
    im = (mi * c + mr * s) >> 15                      # Im(M e^{-j theta})
    sbin = (im * SFO_KB_Q16) >> 20                    # angle units per bin
    rho = ((-ang - FREQ_S * sbin) & 0xFFFFFFFF).astype(np.int64)
    ck, sk = rx_blocks_ref.nco_cs(rho)
    yr = sat16((xr * ck - xi * sk + 16384) >> 15)
    yi = sat16((xr * sk + xi * ck + 16384) >> 15)
    return yr, yi, ang, sbin


def cpe_track_l1(xr, xi):
    """cpe_track() plus the pilot error: l1 = sum over the pilots of |Re(Y_p) - sigma_p*A| + |Im(Y_p)| after the rotation
    (Y = rotated pilot, sigma_p = pilot sign, A = PILOT_AMP).  Golden for the l1 output of phy_phase_tracker."""
    yr, yi, ang = cpe_track(xr, xi)
    sg = pilot_sign()
    l1 = int(np.sum(np.abs(yr[PILOT_S].astype(np.int64) - sg * A_LTS) + np.abs(yi[PILOT_S].astype(np.int64))))
    return yr, yi, ang, l1


def _norm17(a, b):
    m = max(abs(a), abs(b))
    sh = max(0, int(m).bit_length() - 17)
    return a >> sh, b >> sh


# ------------------------------------------------------------------ soft demap, deinterleave, descramble
def demap_deint(xr, xi):
    """data bins -> LLR (8-bit) -> deinterleave -> hard bits -> bytes (still scrambled)"""
    pts = np.stack([xr[DATA_S], xi[DATA_S]], axis=1)
    llr = qam_ref.demap_llr(pts, order=16)                    # (1100, 4)
    words = [sum((int(v) & 0xFF) << (8 * (3 - k)) for k, v in enumerate(row)) for row in llr]
    return words


def llr_words_to_bytes(words_all):
    """words (32-bit packed 4xLLR8) already deinterleaved -> bytes (hard decision: LLR < 0 -> 1)"""
    bits = []
    for w in words_all:
        for k in range(4):
            v = (w >> (8 * (3 - k))) & 0xFF
            bits.append(1 if v >= 128 else 0)
    out = []
    for i in range(0, len(bits), 8):
        b = 0
        for k in range(8):
            b = (b << 1) | bits[i + k]
        out.append(b)
    return out


def rx_decode(sym_words_list, nbytes):
    """sym_words_list: per data symbol the 1100 packed LLR words (interleaved order). Returns descrambled payload bytes."""
    words = []
    for w in sym_words_list:
        words += w
    deint = interleaver_ref.deinterleave(words, 32, 8)
    return scrambler_ref.scramble(llr_words_to_bytes(deint))[:nbytes]       # additive scrambler: same op descrambles


def frame_from_windows(wins, nsyms):
    """wins: list of (win_i, win_q) arrays, first = LTS, then data symbols. Returns (bytes, info)."""
    yr, yi = select_active(*rx_fft(*wins[0]))
    mr, mi, E = chest(yr, yi)
    sym_words, angs = [], []
    for k in range(1, nsyms + 1):
        dr, di = select_active(*rx_fft(*wins[k]))
        xr, xi = equalize(dr, di, mr, mi, E)
        xr, xi, ang = cpe_track(xr, xi)
        angs.append(ang)
        sym_words.append(demap_deint(xr, xi))
    return sym_words, angs


def decode_symbols(data_syms_ri, nbytes):
    """data_syms_ri: list over symbols of (xr, xi) arrays of the 1100 data bins (after the tracker). Returns bytes."""
    words = []
    for xr, xi in data_syms_ri:
        pts = np.stack([xr, xi], axis=1)
        llr = qam_ref.demap_llr(pts, order=16)
        words.append([sum((int(v) & 0xFF) << (8 * (3 - k)) for k, v in enumerate(row)) for row in llr])
    return rx_decode(words, nbytes)
