"""Beamforming TX (TestTask006): bit-exact models of the new PL blocks.

  phy_tx_weight : per-bin weight W[k] = A * exp(j*(phi + 2*pi*ks*tau/N)), ks = signed bin index (k or k-N).
                  phase32 = (phase16 << 16) + ks * tau_q * 2^13 (mod 2^32); (c, s) = nco_cs(phase32) (12-bit table index);
                  coefficient cw = (c*amp + 2^14) >> 15, sw = (s*amp + 2^14) >> 15;
                  y = round_half_up(x * (cw + j*sw) >> 15), saturated to 16 bit (same arithmetic as phy_complex_mult).
                  tau_q in 1/256 sample, tau > 0 ADVANCES the transmitted signal (ifft(X[k] e^{+j2pi k tau/N}) = x[n + tau]).
                  Modes: bypass (y = x exactly), weight, mute (y = 0).
  tau tracker   : tau_acc (48 bit, 2^-32 sample) = tau_q << 24 on apply, += rho (signed 32 bit, 2^-32 sample per DAC sample)
                  on every DAC strobe; tau used for a frame = sat16(tau_acc >> 24) + tick_adj, latched at the frame start.
  tick_adj      : EPOCH tick-phase compensation: the first DAC strobe comes `tick_phase` clocks after the tick, P = 2^log2p clocks
                  per strobe -> the frame is late by tick_phase/P samples -> tau += tick_phase << (8 - log2p).
  output NCO    : y_n = x_n * (cos + j sin)(ph_n), ph_{n+1} = ph_n + inc_n (2^32 = 2*pi per sample), continuous across packets
                  (rx_blocks_ref.nco_cs table); bypass when disabled.
  syncbus frame : [A5][5A][type][seq][len][payload (len bytes)][crc16 hi][crc16 lo], CRC16-CCITT (poly 0x1021, init 0xFFFF)
                  over type..payload. PARAMS (type 1, len 36): epoch_target u32 LE + 2 x channel block (16 bytes):
                  amp u16, phase u16, tau s16, ctrl u16 (bit0 weights on, bit1 NCO on), rho s32, inc u32.
                  SET_EPOCH (type 2, len 4): epoch number u32 taken at the next tick. Other types: stored only (software).
                  Response (follower -> leader, type 0x81, len 16): status u16, crc_err u16, epoch_num u32, ts u64.
"""
import numpy as np
from phy_params import FFT_SIZE, IQ_W
from rx_blocks_ref import nco_cs

N = FFT_SIZE
TAU_FRAC = 8
SYNC = (0xA5, 0x5A)
T_PARAMS, T_SET_EPOCH, T_RESP = 0x01, 0x02, 0x81
LO, HI = -(1 << (IQ_W - 1)), (1 << (IQ_W - 1)) - 1


def sat(v, w=IQ_W):
    return np.clip(v, -(1 << (w - 1)), (1 << (w - 1)) - 1)


def weight_coefs(amp, phase16, tau_q):
    """(cw, sw) Q1.15 for bins k = 0..N-1."""
    k = np.arange(N, dtype=np.int64)
    ks = np.where(k < N // 2, k, k - N)
    ph = ((int(phase16) & 0xFFFF) << 16) + ((ks * int(tau_q)) << 13)
    c, s = nco_cs(ph & 0xFFFFFFFF)
    a = int(amp)
    return (c * a + (1 << 14)) >> 15, (s * a + (1 << 14)) >> 15


def apply_weight(re, im, amp=32767, phase16=0, tau_q=0, mode="bypass"):
    re = np.asarray(re, dtype=np.int64); im = np.asarray(im, dtype=np.int64)
    if mode == "bypass":
        return re.copy(), im.copy()
    if mode == "mute":
        return np.zeros_like(re), np.zeros_like(im)
    cw, sw = weight_coefs(amp, phase16, tau_q)
    return sat((re * cw - im * sw + 16384) >> 15), sat((re * sw + im * cw + 16384) >> 15)


def tx_frame_bf(payload, chans, gain=16384, mask=0x0FF, code="ldpc", mode=0):
    """phy_tx_top BF=1: one frame, per channel weights. chans: list of dict(mode=, amp=, phase=, tau=) (tau = value latched at the
    frame start incl. tick_adj). Returns a list (per channel) of (re, im) sample lists."""
    import tx_ref
    from phy_params import CP_LEN
    n_log = N.bit_length() - 1
    bins = tx_ref.tx_frame_bins(payload, code=code, mode=mode)
    out = []
    for ch in chans:
        o = []
        for re, im in bins:
            wr, wi = apply_weight(re, im, ch.get("amp", 32767), ch.get("phase", 0), ch.get("tau", 0), ch.get("mode", "bypass"))
            rr, ri = tx_ref.ifft_raw(wr, wi, n_log, mask)
            rr, ri = tx_ref.tx_scale(rr, gain), tx_ref.tx_scale(ri, gain)
            cr, ci = tx_ref.cp_insert(rr, ri, n_log, CP_LEN)
            o += [(int(a), int(b)) for a, b in zip(cr, ci)]
        out.append(o)
    return out


def tau_used(tau_set, rho, n_strobes, tick_adj=0):
    acc = (int(tau_set) << 24) + int(n_strobes) * int(rho)
    return int(np.clip(acc >> 24, LO, HI)) + int(tick_adj)


def tick_adj(tick_phase, log2p):
    return int(tick_phase) << (8 - int(log2p))


def nco_stream(xr, xi, inc, ph0=0, en=True):
    """Output NCO over a strobe sequence. inc: scalar or per-strobe array (inc used to advance AFTER sample n).
    Returns (yr, yi, ph_end)."""
    xr = np.asarray(xr, dtype=np.int64); xi = np.asarray(xi, dtype=np.int64)
    inc = np.broadcast_to(np.asarray(inc, dtype=np.int64), xr.shape)
    ph = (int(ph0) + np.concatenate([[0], np.cumsum(inc)[:-1]])) & 0xFFFFFFFF
    ph_end = (int(ph0) + int(np.sum(inc))) & 0xFFFFFFFF
    if not en:
        return xr.copy(), xi.copy(), ph_end
    c, s = nco_cs(ph)
    return sat((xr * c - xi * s + 16384) >> 15), sat((xr * s + xi * c + 16384) >> 15), ph_end


# ------------------------------------------------------------------------------------------------------------- bus frames
def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= (b & 0xFF) << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def le(v, n):
    return [(int(v) >> (8 * i)) & 0xFF for i in range(n)]


def frame(ftype, seq, payload):
    body = [ftype & 0xFF, seq & 0xFF, len(payload) & 0xFF] + [b & 0xFF for b in payload]
    c = crc16(body)
    return list(SYNC) + body + [c >> 8, c & 0xFF]


def ch_block(amp=32767, phase=0, tau=0, weights=False, nco=False, rho=0, inc=0):
    return le(amp, 2) + le(phase, 2) + le(tau & 0xFFFF, 2) + le(int(weights) | (int(nco) << 1), 2) + le(rho & 0xFFFFFFFF, 4) + le(inc, 4)


def params_frame(seq, target, ch0, ch1):
    return frame(T_PARAMS, seq, le(target, 4) + ch_block(**ch0) + ch_block(**ch1))


def resp_frame(seq, status, crc_err, epoch_num, ts):
    return frame(T_RESP, seq, le(status, 2) + le(crc_err, 2) + le(epoch_num, 4) + le(ts, 8))


def parse(frame_bytes):
    """-> dict(type, seq, payload) or None if the sync / length / CRC is wrong."""
    b = list(frame_bytes)
    if len(b) < 7 or b[0] != SYNC[0] or b[1] != SYNC[1]:
        return None
    n = b[4]
    if len(b) != 7 + n or crc16(b[2:5 + n]) != (b[5 + n] << 8 | b[6 + n]):
        return None
    return {"type": b[2], "seq": b[3], "payload": b[5:5 + n]}


def u(b, o, n, signed=False):
    v = sum(b[o + i] << (8 * i) for i in range(n))
    return v - (1 << (8 * n)) if signed and v >> (8 * n - 1) else v


def parse_ch(p, o):
    return {"amp": u(p, o, 2), "phase": u(p, o + 2, 2), "tau": u(p, o + 4, 2, True), "ctrl": u(p, o + 6, 2),
            "rho": u(p, o + 8, 4, True), "inc": u(p, o + 12, 4)}


# ------------------------------------------------------------------------------------------------------------- epoch apply rule
def epoch_apply(new_num, target):
    """At a tick with epoch number new_num: (apply, late) for a pending set with `target` (0xFFFFFFFF = next tick)."""
    if target == 0xFFFFFFFF or target == new_num:
        return True, False
    d = (new_num - target) & 0xFFFFFFFF
    return (d < 0x80000000), (d < 0x80000000)


if __name__ == "__main__":
    # self-checks of the float meaning of the fixed-point weight
    rng = np.random.default_rng(1)
    X = (rng.integers(-8000, 8000, N) + 1j * rng.integers(-8000, 8000, N))
    for amp, ph, tau in [(32767, 0, 0), (20000, 12345, 0), (32767, 0, 256 * 3), (30000, 40000, -517)]:
        yr, yi = apply_weight(X.real, X.imag, amp, ph, tau, "weight")
        k = np.arange(N); ks = np.where(k < N // 2, k, k - N)
        ideal = X * amp / 32768 * np.exp(1j * (2 * np.pi * ph / 65536 + 2 * np.pi * ks * tau / 256 / N))
        err = np.abs((yr + 1j * yi) - ideal)
        bound = np.abs(X) * np.pi / 4096 + 2          # half a 12-bit phase step + rounding
        print(f"amp {amp} phase {ph} tau {tau / 256:+.3f}: max |err| {err.max():.2f} LSB, max err/bound {np.max(err / bound):.2f}")
        assert np.all(err <= bound)
    # tau > 0 advances: ifft(X e^{j2pi k tau/N}) = x[n + tau]
    x = np.fft.ifft(X); y = np.fft.ifft(X * np.exp(2j * np.pi * np.arange(N) * 5 / N))
    assert np.allclose(y, np.roll(x, -5))
    f = params_frame(7, 1234, dict(amp=1000, phase=2, tau=-3, weights=True, rho=-5, inc=99), dict())
    p = parse(f); assert p and p["type"] == 1 and len(f) == 43 and parse_ch(p["payload"], 4)["tau"] == -3
    assert crc16(b"123456789") == 0x29B1
    print("bf_ref self-test passed, PARAMS frame", len(f), "bytes")
