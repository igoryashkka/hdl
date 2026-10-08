"""PHY v2 reference (coded mode): LDPC R=5/6 + soft LLR demapper + MMSE/ZF equalizer + SNR / channel-quality estimator.

TX (per OFDM symbol): 450 payload bytes -> additive scrambler (whole payload) -> 2 x 1800 info bits -> LDPC (2 x 2160 coded bits)
-> 4320 bits + 80 filler bits (alternating 0/1, LLR 0 at the receiver) = 4400 bits -> 1100 nibble words -> the existing symbol
interleaver -> 16-QAM -> same OFDM frame as the uncoded PHY (sync, LTS, data symbols). Payload rate 450 bytes / 71.35 us = 50.5 Mbit/s
before frame overhead.

RX: floating-point reference (the fixed-point blocks are derived from it later): channel estimate from the LTS, noise power from the
unused guard bins, pilot-based common phase, ZF or MMSE equalizer, max-log LLR (uniform or per-bin weighted), de-interleaving, layered
normalised min-sum LDPC decoder (ldpc_ref), descrambling. Quality metrics: signal / noise power, SNR average / minimum, bad
subcarriers, pilot EVM.
"""
from __future__ import annotations

import numpy as np

import interleaver_ref as ilr
import ldpc_ref
import ofdm_ref
import scrambler_ref
from phy_params import (BYTES_PER_OFDM, FFT_SIZE, NUM_ACTIVE_SC, NUM_DATA_SC, PILOT_AMP, QAM_UNIT)

# dual mode (ТЗ 003): MODE_ID 0 = MAX RANGE (QPSK, LDPC 1/2, 135 bytes / symbol), 1 = MAX RATE (16-QAM, LDPC 5/6, 450 bytes / symbol).
# The ablation study also uses the other combinations (a tuple (modulation, rate) instead of a mode id, python only):
# ("qpsk", "r56") = 225 bytes / symbol (one codeword), ("16qam", "r12") = 270 bytes / symbol (two codewords).
MODES = {0: ("qpsk", "r12"), 1: ("16qam", "r56")}
MODE_NAMES = {0: "MAX_RANGE", 1: "MAX_RATE"}


def layout(mode) -> dict:
    """mode: 0 / 1 (MODE_ID) or a (modulation, code) tuple -> dict(mod, bits per bin, code, base, k, cw per symbol, bytes per symbol)."""
    mod, code = MODES[int(mode)] if not isinstance(mode, tuple) else mode
    bits = 2 if mod == "qpsk" else 4
    base = ldpc_ref.CODES[code]
    k = ldpc_ref.code_info_bits(base)
    cw = (NUM_DATA_SC * bits) // ldpc_ref.N
    return {"mod": mod, "bits": bits, "code": code, "base": base, "k": k, "cw": cw, "bytes": cw * k // 8,
            "id": (0 if mod == "qpsk" and code == "r12" else 1 if mod == "16qam" and code == "r56" else None),
            "fill": (np.arange(NUM_DATA_SC * bits - cw * ldpc_ref.N) & 1).astype(np.uint8)}


def mode_base(mode):
    return layout(mode)["base"]


def mode_k(mode) -> int:
    return layout(mode)["k"]


def info_bytes_per_sym(mode) -> int:
    return layout(mode)["bytes"]


def fill_bits(mode) -> np.ndarray:
    """filler bits that complete a symbol (alternating 0 / 1): 80 for 16-QAM (4400 - 4320), 40 for QPSK (2200 - 2160)."""
    return layout(mode)["fill"]


CODE_K = ldpc_ref.K                    # 1800 info bits per codeword
CODE_N = ldpc_ref.N                    # 2160
CW_PER_SYM = 2
INFO_BYTES_PER_SYM = CW_PER_SYM * CODE_K // 8     # 450
CODED_BITS = CW_PER_SYM * CODE_N                   # 4320
SYM_BITS = NUM_DATA_SC * 4                         # 4400
FILL = (np.arange(SYM_BITS - CODED_BITS) & 1).astype(np.uint8)
P_DATA = 10.0 * QAM_UNIT ** 2                      # mean power of a 16-QAM point (per complex symbol)


def bytes_per_sym(code: str) -> int:
    return INFO_BYTES_PER_SYM if code == "ldpc" else BYTES_PER_OFDM


# ------------------------------------------------------------------ TX
def tx_words(payload: bytes, nsym: int, code: str = "ldpc", mode: int = 1) -> list[int]:
    """Interleaved words (nsym * 1100) of the data symbols: 16-QAM nibbles (mode 1) or 2 bit QPSK words {I, Q} (mode 0, no rotation)."""
    if code != "ldpc":
        bps = bytes_per_sym(code)
    else:
        bps = info_bytes_per_sym(mode)
    data = list(payload) + [0] * (nsym * bps - len(payload))
    sc = np.array(scrambler_ref.scramble(data), dtype=np.uint8)
    bits = np.unpackbits(sc)
    if code != "ldpc":
        allbits = bits
    else:
        m = layout(mode)
        info = bits.reshape(nsym * m["cw"], m["k"])
        cw = ldpc_ref.encode(info, m["base"]).reshape(nsym, m["cw"] * ldpc_ref.N)
        allbits = np.concatenate([cw, np.tile(m["fill"], (nsym, 1))], axis=1).reshape(-1)
        if m["mod"] == "qpsk":
            w = allbits.reshape(-1, 2)
            return ilr.interleave([int(a) << 1 | int(b) for a, b in w], 4, 0)
    w = allbits.reshape(-1, 4)
    words = [int(a) << 3 | int(b) << 2 | int(c) << 1 | int(d) for a, b, c, d in w]
    return ilr.interleave(words, 4, 1)


# ------------------------------------------------------------------ RX helpers
_DEINT = None


def _deint_index():
    """index arrays: for deinterleaved word i take received word m[i]; odd m words had their 4 bits rotated left by one."""
    global _DEINT
    if _DEINT is None:
        n = NUM_DATA_SC
        m = np.array([ilr.pi_inv(i) for i in range(n)])
        _DEINT = (m, (m & 1).astype(bool))
    return _DEINT


def deinterleave_llr(llr: np.ndarray) -> np.ndarray:
    """llr: (nsym, 1100, 4) in transmitted (interleaved) order -> (nsym, 4400) bit LLRs in coded-bit order.
    (nsym, 1100, 2) QPSK LLRs [I, Q]: plain permutation (no rotation) -> (nsym, 2200)."""
    m, odd = _deint_index()
    out = np.empty_like(llr)
    qpsk = llr.shape[-1] == 2
    for s in range(llr.shape[0]):
        g = llr[s][m]
        if not qpsk:
            g[odd] = np.roll(g[odd], 1, axis=1)
        out[s] = g
    return out.reshape(llr.shape[0], -1)


_LEV = np.array([-3.0, -1.0, 1.0, 3.0])
_B0 = np.array([0, 0, 1, 1])       # Gray: level -3 -> 00, -1 -> 01, +1 -> 11, +3 -> 10  (bit0, bit1)
_B1 = np.array([0, 1, 1, 0])


def llr16(xhat: np.ndarray, var_axis, scale=1.0) -> np.ndarray:
    """Exact max-log LLR of 16-QAM points (unit QAM_UNIT). xhat complex (any shape); var_axis = noise variance per real axis
    (scalar or array, units of xhat^2); scale = constellation shrink mu (MMSE bias; scalar or array broadcast over xhat).
    Returns (..., 4): [I b0, I b1, Q b0, Q b1]; positive = bit 0."""
    u = QAM_UNIT
    sc = np.broadcast_to(np.asarray(scale, dtype=float), xhat.shape)[..., None]
    lev = _LEV * sc
    v = 2.0 * np.asarray(var_axis, dtype=float) / u ** 2
    out = []
    for comp in (xhat.real, xhat.imag):
        d = (comp[..., None] / u - lev) ** 2
        l0 = d[..., _B0 == 1].min(-1) - d[..., _B0 == 0].min(-1)
        l1 = d[..., _B1 == 1].min(-1) - d[..., _B1 == 0].min(-1)
        out += [l0 / v, l1 / v]
    return np.stack(out, axis=-1)


# ------------------------------------------------------------------ channel / noise / quality estimation
ACT = np.array([b for b in range(FFT_SIZE) if ofdm_ref.s_of_bin(b) >= 0])
LTS_SG = None


def _lts_sg():
    global LTS_SG
    if LTS_SG is None:
        import phy_params as P
        bits = ofdm_ref.lfsr_bits(P.LTS_SEED, NUM_ACTIVE_SC)
        LTS_SG = np.array([-1.0 if b else 1.0 for b in bits])
    return LTS_SG


def _pilot_sg():
    import phy_params as P
    bits = ofdm_ref.lfsr_bits(P.PILOT_SEED, P.NUM_PILOTS)
    return np.array([-1.0 if b else 1.0 for b in bits])


_PS = np.array([s for s in range(NUM_ACTIVE_SC) if ofdm_ref.is_pilot_slot(s)])
_DS = np.array([s for s in range(NUM_ACTIVE_SC) if not ofdm_ref.is_pilot_slot(s)])
GUARD = np.array([b for b in range(700, 1349)])          # unused bins far from the band edge (|k| >= 700): noise only


def noise_power(yfull: np.ndarray) -> float:
    """Noise power per complex FFT bin (raw FFT units^2) from the guard bins of one FFT output (2048 complex)."""
    return float(np.mean(np.abs(yfull[GUARD]) ** 2))


def channel_estimate(y_lts: np.ndarray, smooth: int = 0) -> np.ndarray:
    """H_k = Y_k * sign_k / A (1200 active bins). smooth > 0: moving average over +-smooth bins (channel is short in time)."""
    h = y_lts * _lts_sg() / PILOT_AMP
    if smooth:
        k = np.ones(2 * smooth + 1) / (2 * smooth + 1)
        hp = np.concatenate([h[:smooth][::-1], h, h[-smooth:][::-1]])
        h = np.convolve(hp, k, mode="valid")
    return h


def common_phase(y: np.ndarray, h: np.ndarray) -> float:
    z = np.sum(np.conj(h[_PS] * _pilot_sg() * PILOT_AMP) * y[_PS])
    return float(np.angle(z))


def equalize(y: np.ndarray, h: np.ndarray, nu: float, mode: str = "mmse"):
    """y, h: 1200 active bins. nu = noise power / mean symbol power (raw units). Returns (xhat, mu): xhat in TX constellation units."""
    h2 = np.abs(h) ** 2
    if mode == "zf":
        w = np.conj(h) / np.maximum(h2, 1e-30)
        return y * w, np.ones_like(h2)
    w = np.conj(h) / (h2 + nu)
    return y * w, h2 / (h2 + nu)


def quality(h: np.ndarray, sigma2: float, thr_db: float = 12.0) -> dict:
    """Signal / noise / SNR of the channel: per-subcarrier SNR_k = |H_k|^2 P_data / sigma2."""
    snr = np.abs(h) ** 2 * P_DATA / max(sigma2, 1e-30)
    sdb = 10 * np.log10(np.maximum(snr, 1e-12))
    return {"signal_power": float(np.mean(np.abs(h) ** 2) * P_DATA), "noise_power": float(sigma2),
            "snr_avg_db": float(10 * np.log10(np.mean(snr))), "snr_min_db": float(sdb.min()),
            "bad_subcarriers": int((sdb < thr_db).sum()), "snr_k_db": sdb}


def rx_symbols(y_lts_full: np.ndarray, y_data_full: list, eq: str = "mmse", soft: str = "weighted", smooth: int = 0) -> dict:
    """FFT outputs (complex, 2048 bins, natural order) of the LTS window and of every data window -> LLRs + diagnostics."""
    h = channel_estimate(y_lts_full[ACT], smooth)
    s2 = noise_power(y_lts_full)
    s2 = float(np.mean([s2] + [noise_power(y) for y in y_data_full]))
    nu = s2 / P_DATA
    llrs, evm_l1, thetas = [], [], []
    for yf in y_data_full:
        y = yf[ACT]
        th = common_phase(y, h)
        y = y * np.exp(-1j * th)
        xh, mu = equalize(y, h, nu, eq)
        thetas.append(th)
        pil = xh[_PS] / np.maximum(mu[_PS], 1e-9)
        evm_l1.append(float(np.mean(np.abs(pil - _pilot_sg() * PILOT_AMP))))
        xd, mud, hd = xh[_DS], mu[_DS], h[_DS]
        h2 = np.abs(hd) ** 2
        if soft == "weighted":                      # per-bin reliability: noise var of the (bias-scaled) estimate
            var = (s2 * h2 / (h2 + nu) ** 2) / 2.0
            llr = llr16(xd, var, scale=mud)
        else:                                       # uniform: one global noise variance, no per-bin knowledge
            var = np.full(len(xd), s2 / np.mean(h2) / 2.0)
            llr = llr16(xd, var, scale=1.0)
        llrs.append(llr)
    q = quality(h, s2)
    q["evm_pilot_l1"] = float(np.mean(evm_l1))
    q["common_phase"] = thetas
    return {"llr": np.stack(llrs), "quality": q, "h": h, "sigma2": s2}


def decode_payload(llr_sym: np.ndarray, nsym: int, nbytes: int, iters: int = 20, alpha: float = 0.75,
                   max_llr: float | None = None, mode: int = 1) -> dict:
    """llr_sym: (nsym, 1100, 4) (mode 1) or (nsym, 1100, 2) (mode 0). Returns payload bytes + LDPC statistics."""
    m = layout(mode)
    deint = deinterleave_llr(llr_sym)                    # (nsym, 4400 | 2200)
    cw_llr = deint[:, :m["cw"] * CODE_N].reshape(nsym * m["cw"], CODE_N)
    if max_llr is not None:
        cw_llr = np.clip(cw_llr, -max_llr, max_llr)
    hard, used, ok = ldpc_ref.decode(cw_llr, iters=iters, alpha=alpha, base=mode_base(mode))
    info = hard[:, :mode_k(mode)].reshape(-1)
    data = np.packbits(info)
    raw = scrambler_ref.scramble(list(data))             # additive scrambler: same operation descrambles
    return {"bytes": bytes(raw[:nbytes]), "iterations": used, "ok": ok, "hard_info": hard[:, :CODE_K]}
