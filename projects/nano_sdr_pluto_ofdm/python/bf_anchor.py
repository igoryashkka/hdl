"""Anchor (board B) of the beamforming loop (TestTask006): float reference, mirrored by sw/beamd (C).

Sounding (TZ 4.1): in every epoch antenna a sends a sounding packet (sync, LTS, header, 1 data symbol; unit weights, NCO on) at the
launch index slot_a(e) after the EPOCH tick of its board. Unequal slot gaps identify the antennas without decoding, and the gap
S0 -> S1 carries the epoch number modulo 8: slot_1(e) = SLOT_BASE[1] + SLOT_STEP * (e mod 8) (see slots_for / assign), so the anchor
can name the epoch its parameters are for (target = (e + D) mod 8) without seeing the EPOCH wire.

Per sounding packet (estimate()):
  coarse timing / CFO : Schmidl-Cox on the sync symbol (half-symbol repetition, L = N/2), CFO = angle(sum P) / (2 pi L) * fs
  channel             : FFT of the LTS body (window 32 samples inside the CP, CFO removed relative to the window start),
                        H(k) = Y(k) / X_LTS(k) on the 1200 active bins
  delay               : slope of the phase over the band: lag products sum H(k+m) H*(k) for m = 1, 16, 128 (each lag resolves the
                        ambiguity of the next), then a least-squares fit of the residual phase over all 1200 bins (near the
                        Cramer-Rao bound, ~0.002 sample at 20 dB); arrival t = window start + d (B samples, fractional)
  phase / amplitude   : phase = angle(sum H(k) exp(+j 2 pi ks d / N)) + 2 pi f d / fs = carrier phase at the arrival, amp = mean |H|
Control (Controller): per antenna Kalman filter on {phase, frequency, frequency drift} across epochs (raw quantities: the anchor adds
back the NCO frequency it commanded), prediction to the data time of the epoch where the new parameters take effect, and:
  weight phase  = -(predicted phase of a - predicted phase of antenna 0) at the data time      (2^16 = 2 pi)
  tau (advance) = arrival offset of a relative to antenna 0 at the data launch index           (1/256 sample)
  rho           = (nu_raw(ref) - nu_raw(board)) / f_carrier   (sample-clock drift inside the epoch, 2^-32 sample per sample)
  NCO           = -(nu_raw(board) - nu_raw(ref))  for the boards other than the reference      (2^32 = 2 pi per sample)
  amplitude     = MRT (|h_a| / max |h|) or equal gain.
"""
import numpy as np
from phy_params import FFT_SIZE, CP_LEN, SYMBOL_LEN, SAMPLE_RATE_HZ
import ofdm_ref

N = FFT_SIZE
L = N // 2
FS = float(SAMPLE_RATE_HZ)
BACKOFF = 32
_lts = ofdm_ref.preamble(1)
LTS = np.array([a + 1j * b for a, b in _lts])
ACT = np.array([b for b in range(N) if ofdm_ref.s_of_bin(b) >= 0])
KS = np.where(ACT < N // 2, ACT, ACT - N)
_ord = np.argsort(KS)
ACT_S, KS_S = ACT[_ord], KS[_ord]                         # active bins sorted by signed frequency (-600 .. 600)
ADJ = np.where(np.diff(KS_S) == 1)[0]                     # adjacent pairs (skip the DC gap)
LAGS = (1, 16, 128)
_pos = {int(k): i for i, k in enumerate(KS_S)}
LAG_PAIRS = {m: np.array([[_pos[k], _pos[k + m]] for k in KS_S if (k + m) in _pos and (k > 0) == (k + m > 0)]) for m in LAGS}


def delay_est(H):
    """delay d (samples) of H(k) ~ exp(-j 2 pi ks d / N) on the sorted active bins."""
    d = 0.0
    for m in LAGS:
        p = LAG_PAIRS[m]
        Hc = H * np.exp(2j * np.pi * KS_S * d / N)
        sl = np.angle(np.sum(Hc[p[:, 1]] * np.conj(Hc[p[:, 0]])))
        d += -sl * N / (2 * np.pi * m)
    Hc = H * np.exp(2j * np.pi * KS_S * d / N)
    ph = np.angle(Hc * np.conj(np.mean(Hc)))
    w = np.abs(Hc)
    k = KS_S - np.sum(w * KS_S) / np.sum(w)
    slope = np.sum(w * k * ph) / np.sum(w * k * k)
    return d - slope * N / (2 * np.pi)


def sc_metric(r):
    """P(n) = sum_{m<L} conj(r[n+m]) r[n+m+L], R(n) = sum_{m<L} |r[n+m+L]|^2, for n = 0 .. len(r)-2L."""
    pr = np.conj(r[:-L]) * r[L:]
    cp = np.concatenate([[0], np.cumsum(pr)])
    e = np.abs(r[L:]) ** 2
    ce = np.concatenate([[0], np.cumsum(e)])
    n = len(r) - 2 * L + 1
    P = cp[L:L + n] - cp[:n]
    R = ce[L:L + n] - ce[:n]
    return P, R


def detect(r, thr=0.2, min_gap=3 * SYMBOL_LEN):
    """-> list of (sync body start estimate, P sum over the plateau) for every packet."""
    P, R = sc_metric(r)
    M = np.abs(P) ** 2 / np.maximum(R, 1e-12) ** 2
    above = np.where(M > thr)[0]
    out = []
    i = 0
    while i < len(above):
        j = i
        while j + 1 < len(above) and above[j + 1] - above[j] < 64:
            j += 1
        seg = above[i:j + 1]
        if len(seg) > CP_LEN // 4:
            mx = M[seg].max()
            plat = seg[M[seg] > 0.9 * mx]
            s_end = int(plat[-1])
            if not out or s_end - out[-1][0] > min_gap:
                out.append((s_end, P[plat].sum()))
        i = j + 1
    return out


def estimate(r, s_sync, Psum):
    """One sounding packet: s_sync = estimated sync body start. -> dict(t, f, phi, amp, snr) or None."""
    f = np.angle(Psum) / (2 * np.pi * L) * FS
    w0 = s_sync + SYMBOL_LEN - BACKOFF                    # LTS window start (inside the LTS CP)
    if w0 + N > len(r) or w0 < 0:
        return None
    n = np.arange(N)
    seg = r[w0:w0 + N] * np.exp(-2j * np.pi * f * n / FS)
    Y = np.fft.fft(seg)
    H = Y[ACT_S] / LTS[ACT_S]
    d = delay_est(H)
    Hc = H * np.exp(2j * np.pi * KS_S * d / N)
    g = np.mean(Hc)
    phi = np.angle(g) + 2 * np.pi * f * d / FS          # carrier phase at the arrival (the CFO was removed relative to w0)
    amp = np.abs(g)
    noise = np.mean(np.abs(Hc - g) ** 2)
    return {"t": w0 + d, "f": f, "phi": phi, "amp": amp, "snr_db": 10 * np.log10(amp ** 2 / max(noise, 1e-30)), "w0": w0}


SLOT_BASE = (1000, 13000, 27000, 43000)
SLOT_STEP = 64


def slots_for(epoch):
    s = list(SLOT_BASE)
    s[1] += SLOT_STEP * (epoch % 8)
    return s


def assign(dets, tol=24):
    """Find 4 consecutive detections matching the slot pattern (S1 shifted by 64 * (e mod 8)).
    -> (list of 4 detections, e mod 8, slots of that epoch) or None."""
    g02 = SLOT_BASE[2] - SLOT_BASE[0]; g23 = SLOT_BASE[3] - SLOT_BASE[2]
    for i in range(len(dets) - 3):
        t = [dets[i + k][0] for k in range(4)]
        if abs((t[2] - t[0]) - g02) < tol and abs((t[3] - t[2]) - g23) < tol:
            m = (t[1] - t[0] - (SLOT_BASE[1] - SLOT_BASE[0])) / SLOT_STEP
            mi = int(round(m))
            if 0 <= mi < 8 and abs(m - mi) * SLOT_STEP < tol:
                return [dets[i + k] for k in range(4)], mi, slots_for(mi)
    return None


class Kalman:
    """state x = [phase (rad), frequency (Hz), drift (Hz/s)], time in seconds.
    Alias guard: phases measured once per epoch cannot tell frequencies k/dt apart; the coarse CFO (Schmidl-Cox, unbiased but
    noisy) is averaged against the state over ALIAS_N updates and the state is moved by k/dt when the mean exceeds half a step."""
    ALIAS_N = 8

    def __init__(self, q_drift=1.0, r_phase=0.05 ** 2, r_freq=30.0 ** 2):
        self.acc, self.nacc = 0.0, 0
        self.x = None
        self.P = np.diag([10.0, 1e6, 1e4])
        self.q = q_drift
        self.rp, self.rf = r_phase, r_freq

    def F(self, dt):
        return np.array([[1, 2 * np.pi * dt, np.pi * dt * dt], [0, 1, dt], [0, 0, 1]])

    def predict_x(self, dt):
        return self.F(dt) @ self.x

    def Qm(self, dt):
        return self.q * np.array([[(2 * np.pi) ** 2 * dt ** 5 / 20, 2 * np.pi * dt ** 4 / 8, 2 * np.pi * dt ** 3 / 6],
                                  [2 * np.pi * dt ** 4 / 8, dt ** 3 / 3, dt ** 2 / 2],
                                  [2 * np.pi * dt ** 3 / 6, dt ** 2 / 2, dt]])

    def predict(self, dt):
        """time update only (x, P with process noise), e.g. up to an NCO step inside a measurement interval"""
        F = self.F(dt)
        self.x = F @ self.x
        self.P = F @ self.P @ F.T + self.Qm(dt)

    def update(self, dt, phase, freq_coarse, dt_alias=None):
        """dt: prediction interval; dt_alias: time since the previous measurement (the alias step is 1 / dt_alias; it differs from
        dt when the interval was split at an NCO step)."""
        if self.x is None:
            self.x = np.array([phase, freq_coarse, 0.0])
            return
        F = self.F(dt)
        Q = self.Qm(dt)
        x = F @ self.x
        P = F @ self.P @ F.T + Q
        da = dt if dt_alias is None else dt_alias
        if da > 0:
            self.acc += freq_coarse - x[1]; self.nacc += 1
            if self.nacc >= self.ALIAS_N:
                m = self.acc / self.nacc
                k = round(m * da)
                if k != 0:
                    x[1] += k / da
                self.acc, self.nacc = 0.0, 0
        z_ph = x[0] + np.angle(np.exp(1j * (phase - x[0])))          # unwrap to the prediction
        Hm = np.array([[1, 0, 0], [0, 1, 0]])
        Rm = np.diag([self.rp, self.rf])
        S = Hm @ P @ Hm.T + Rm
        K = P @ Hm.T @ np.linalg.inv(S)
        x = x + K @ (np.array([z_ph, freq_coarse]) - Hm @ x)
        self.x, self.P = x, (np.eye(3) - K @ Hm) @ P

    def shift_freq(self, df):
        if self.x is not None:
            self.x[1] += df


class Controller:
    """Anchor logic over epochs. board_of: antenna -> board; antenna 0 (board 0) is the phase / frequency reference.
    The Kalman filters track the MEASURED (post-NCO) phase and frequency of every antenna; an NCO change of a board at a tick is a
    known control input (frequency step at the tick time). Raw frequency (oscillator offset) = state - NCO in force."""

    def __init__(self, slots, data_launch, fc, board_of=(0, 0, 1, 1), mrt=True, kal=None):
        self.slots = np.asarray(slots, dtype=float)
        self.ld = data_launch
        self.fc = fc
        self.board_of = list(board_of)
        self.nb = max(board_of) + 1
        self.mrt = mrt
        self.kf = [Kalman(**(kal or {})) for _ in board_of]
        self.t_last = [None] * len(board_of)
        self.nco = np.zeros(self.nb)                              # NCO frequency in force per board (Hz)
        self.events = []                                          # (t, board, delta Hz) not yet folded into the filters
        self.meas = [None] * len(board_of)

    def nco_at(self, b, t):
        """NCO frequency of board b in force at time t (scheduled steps after t not yet effective)."""
        return self.nco[b] - sum(d for (te, bb, d) in self.events if bb == b and te > t)

    def nco_change(self, t, board, new_hz):
        """Schedule an NCO change of `board` that takes effect at time t (may be in the future)."""
        d = new_hz - self.nco[board]
        if d != 0.0:
            self.events.append((t, board, d))
            self.nco[board] = new_hz

    def _advance(self, a, t_to):
        """Propagate filter a from t_last to t_to applying the NCO steps of its board in between (prediction only)."""
        kf = self.kf[a]
        x = kf.x.copy(); t = self.t_last[a]
        for (te, b, d) in sorted(self.events):
            if b == self.board_of[a] and t < te <= t_to:
                x = kf.F(te - t) @ x; x[1] += d; t = te
        return kf.F(t_to - t) @ x, t

    def update(self, ests, slots=None):
        if slots is not None:
            self.slots = np.asarray(slots, dtype=float)
        for a, e in enumerate(ests):
            if e is None:
                continue
            t = e["t"] / FS
            kf = self.kf[a]
            if self.t_last[a] is None:
                kf.update(0.0, e["phi"], e["f"])
            else:
                # fold the NCO steps into the state, then a normal predict / update over the rest of the interval
                tt = self.t_last[a]
                for (te, b, d) in sorted(self.events):
                    if b == self.board_of[a] and tt < te <= t:
                        kf.predict(te - tt); kf.x[1] += d; tt = te
                kf.update(t - tt, e["phi"], e["f"], dt_alias=t - self.t_last[a])
            self.t_last[a] = t
            self.meas[a] = e
        ts = [t for t in self.t_last if t is not None]
        if ts:
            self.events = [ev for ev in self.events if ev[0] > min(ts)]

    def params(self, t_tick, t_data, slots_next=None):
        """Parameters that take effect at the tick (B time t_tick, s) for data at t_data (s).
        -> (params[board][channel] dicts in bf_ref units, nco Hz per board)."""
        na = len(self.board_of)
        ref = [self.board_of.index(b) for b in range(self.nb)]
        raw = np.array([self.kf[ref[b]].x[1] - self.nco_at(b, self.t_last[ref[b]]) for b in range(self.nb)])
        nco_new = -(raw - raw[0]); nco_new[0] = 0.0
        ph = np.zeros(na); amps = np.zeros(na)
        for a in range(na):
            b = self.board_of[a]
            # measured-frequency model up to the tick, then the frequency changes by the NCO step
            x_tick, _ = self._advance(a, t_tick)
            x_tick = x_tick.copy(); x_tick[1] += nco_new[b] - self.nco[b]
            x_d = self.kf[a].F(t_data - t_tick) @ x_tick
            ph[a] = x_d[0]
            amps[a] = self.meas[a]["amp"] if self.meas[a] else 0.0
        eps = raw / self.fc                                         # sample-clock offset of every board (same crystal as the LO)
        params = [[None, None] for _ in range(self.nb)]
        for a in range(na):
            b = self.board_of[a]
            c = a - ref[b]
            rho = -(eps[b] - eps[0])
            off_slot = (self.meas[a]["t"] - self.slots[a]) - (self.meas[0]["t"] - self.slots[0])
            off_data = off_slot + rho * (self.ld - self.slots[a])
            tau_set = off_data - rho * self.ld                      # tau(n) = tau_set + rho n, n = strobes since the tick
            ph_w = -(ph[a] - ph[0])
            amp = (amps[a] / amps.max()) if self.mrt else 1.0
            params[b][c] = {"amp": int(round(32767 * amp)), "phase": int(round(ph_w / (2 * np.pi) * 65536)) & 0xFFFF,
                            "tau": int(round(tau_set * 256)), "rho": int(round(rho * 2 ** 32)),
                            "inc": int(round(nco_new[b] / FS * 2 ** 32)) & 0xFFFFFFFF, "weights": True, "nco": b != 0}
        return params, nco_new
