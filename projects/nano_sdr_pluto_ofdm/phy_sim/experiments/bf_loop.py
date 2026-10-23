"""Closed-loop beamforming simulation (TestTask006 7.1): 2 boards x 2 channels -> anchor B.

Physics (B time axis, samples at fs):
  board b: oscillator offset nu_b(t) [Hz] = nu0 + drift*t + random walk; the sample clock comes from the same crystal:
           eps_b = nu_b / f_c; EPOCH tick of the leader every `period` of its strobes; the follower sees the tick with a random
           sub-clock delay (2-FF sampling of the JP5 edge, after the tick-phase compensation): U(-1/8, +1/8) sample per epoch.
  antenna a: complex gain g_a, propagation delay delta_a (fractional samples), LO phase noise (Wiener, linewidth per board).
  TX: unit-weight sounding packets at the launch index SLOT[a] (waveform: sync, LTS, header, 1 data symbol, float IFFT),
      NCO frequency per board in force; data packets of all antennas at the launch index LD with the weights / tau / rho / NCO
      quantised as in the PL (bf_ref units).
Anchor: bf_anchor.detect / estimate on the noisy received sounding waveforms, Controller (Kalman) -> parameters applied D epochs later.
Metrics per epoch (data packet): array gain at equal total power G = mean_k |sum_a w_a(k) h_a(k)|^2 / (sum_a |w_a|^2 mean|h|^2)
(ideal 4 = 6.02 dB for equal |h|), loss = ideal - G, residual phase error of every antenna (deg, band average incl. timing).
usage: python experiments/bf_loop.py [--quick] [--out results/bf]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))
import bf_anchor  # noqa: E402
import tx_ref  # noqa: E402
from phy_params import FFT_SIZE, CP_LEN, SAMPLE_RATE_HZ, SYMBOL_LEN  # noqa: E402

N = FFT_SIZE
FS = float(SAMPLE_RATE_HZ)
FC = 2.45e9
BOARD_OF = (0, 0, 1, 1)
SLOTS = np.array([1000, 13000, 27000, 43000])          # unequal gaps 12000, 14000, 16000 identify the antennas
LD = 60000                                              # data launch index
ACT = bf_anchor.ACT
KS = np.where(ACT < N // 2, ACT, ACT - N)


def sounding_waveform():
    rng = np.random.default_rng(5)
    bins = tx_ref.tx_frame_bins(list(rng.integers(0, 256, 135)), code="ldpc", mode=0)
    out = []
    for re, im in bins:
        x = np.fft.ifft(re + 1j * im)
        out.append(np.concatenate([x[-CP_LEN:], x]))
    x = np.concatenate(out)
    return x / np.sqrt(np.mean(np.abs(x) ** 2))


XS = sounding_waveform()


def place(x, t0, length, g, f_hz, phase0):
    """Received copy of x starting at fractional time t0 inside a window [0, length): gain g, CFO f, carrier phase phase0 at t0."""
    i0 = int(np.floor(t0)); fr = t0 - i0
    M = 1 << int(np.ceil(np.log2(len(x) + 64)))
    X = np.fft.fft(np.concatenate([x, np.zeros(M - len(x))]))
    k = np.fft.fftfreq(M) * M
    xs = np.fft.ifft(X * np.exp(-2j * np.pi * k * fr / M))
    y = np.zeros(length, dtype=complex)
    a, b = max(i0, 0), min(i0 + M, length)
    n = np.arange(a, b)
    y[a:b] = g * xs[n - i0] * np.exp(1j * (phase0 + 2 * np.pi * f_hz * (n - t0) / FS))
    return y


class Board:
    def __init__(self, rng, nu0, drift, rw, lw):
        self.nu0, self.drift, self.rw, self.lw = nu0, drift, rw, lw
        self.rng = rng
        self.walk = 0.0
        self.pn = 0.0                   # LO phase noise (rad)
        self.phase = rng.uniform(0, 2 * np.pi)   # carrier phase accumulated (rad) at the current time
        self.t = 0.0
        self.nco = 0.0                  # Hz in force

    def nu(self, t):
        return self.nu0 + self.drift * t + self.walk

    def advance(self, t_new):
        """integrate the carrier phase (oscillator + NCO) from self.t to t_new (s)."""
        dt = t_new - self.t
        if dt <= 0:
            return
        self.phase += 2 * np.pi * ((self.nu(self.t) + self.nco) * dt + 0.5 * self.drift * dt * dt)
        self.walk += self.rw * np.sqrt(dt) * self.rng.standard_normal()
        self.pn += np.sqrt(2 * np.pi * self.lw * dt) * self.rng.standard_normal()
        self.t = t_new

    def carrier(self):
        return self.phase + self.pn


def run(scn, epochs=150, epoch_ms=10.0, D=2, snr_db=20.0, seed=1, mrt=True, kal=None, verbose=False, loss=0.0):
    """loss: probability that a feedback message is lost (the boards keep the previous parameters, the anchor does not know)"""
    rng = np.random.default_rng(seed)
    period = int(round(epoch_ms * 1e-3 * FS))
    if SLOTS[-1] + 12000 > LD or LD + 12000 > period:
        raise ValueError("epoch too short for the slots")
    boards = [Board(rng, rng.uniform(-1, 1) * scn["ppm"] * 1e-6 * FC, scn["drift"] * rng.choice([-1, 1]), scn["rw"], scn["lw"])
              for _ in range(2)]
    g = (rng.uniform(0.7, 1.0, 4) * np.exp(2j * np.pi * rng.uniform(0, 1, 4)))
    delta = np.array([3.0, 3.0, 3.0, 3.0]) + rng.uniform(-0.6, 0.6, 4)       # path differences of a few tens of cm
    ant_ph = rng.uniform(0, 2 * np.pi, 4)                                       # static phase per TX chain
    ctl = bf_anchor.Controller(SLOTS, LD, FC, BOARD_OF, mrt=mrt, kal=kal)
    pending = {}                       # epoch -> (params, nco)
    active = None
    sigma = 10 ** (-snr_db / 20)       # noise rms relative to one antenna at unit gain
    hist = []
    T = 0.0                            # B time of the leader tick (samples)
    for k in range(epochs):
        eps = [b.nu(T / FS) / FC for b in boards]
        skew = [0.0, rng.uniform(-0.125, 0.125)]
        tick = [T + skew[0], T + skew[1]]
        if k in pending and rng.random() < loss:
            pending.pop(k)
        if k in pending:
            active = pending.pop(k)
            for bi, b in enumerate(boards):
                b.advance(tick[bi] / FS)
                b.nco = active[1][bi]

        # ---------------- soundings
        ests = []
        for a in range(4):
            bi = BOARD_OF[a]; b = boards[bi]
            t0 = tick[bi] + SLOTS[a] / (1 + eps[bi]) + delta[a]
            b.advance(t0 / FS)
            win0 = int(t0) - 3000
            y = place(XS, t0 - win0, len(XS) + 6000, abs(g[a]), b.nu(b.t) + b.nco, b.carrier() + np.angle(g[a]) + ant_ph[a])
            y += sigma * (rng.standard_normal(len(y)) + 1j * rng.standard_normal(len(y))) / np.sqrt(2)
            d = bf_anchor.detect(y)
            e = bf_anchor.estimate(y, *d[0]) if d else None
            if e:
                e["t"] += win0
            ests.append(e)
        ctl.update(ests)

        # ---------------- data packet of this epoch with the active parameters
        if active is not None:
            params = active[0]
            C = np.zeros(len(ACT), dtype=complex); wsum = 0.0
            res = []
            for a in range(4):
                bi = BOARD_OF[a]; c = a - (0 if bi == 0 else 2); b = boards[bi]; p = params[bi][c]
                tau = (p["tau"] / 256 + (p["rho"] / 2 ** 32) * LD)
                t_arr = tick[bi] + LD / (1 + eps[bi]) + delta[a] - tau
                b.advance(t_arr / FS)
                A = p["amp"] / 32768
                w = A * np.exp(1j * (2 * np.pi * p["phase"] / 65536))
                h = abs(g[a]) * np.exp(1j * (b.carrier() + np.angle(g[a]) + ant_ph[a]))
                C += w * h * np.exp(-2j * np.pi * KS * t_arr / N)
                wsum += A * A
                res.append((np.angle(w * h), t_arr))
            wi = np.abs(g) / np.abs(g).max() if mrt else np.ones(4)            # ideal amplitudes (MRT or equal gain)
            ideal = np.sum(np.abs(g) * wi) ** 2 / (np.sum(wi ** 2) * np.mean(np.abs(g) ** 2))
            G = np.mean(np.abs(C) ** 2) / (wsum * np.mean(np.abs(g) ** 2))
            ph0, t0 = res[0]
            perr = [float(np.degrees(np.sqrt(np.mean(np.angle(np.exp(1j * (ph - ph0 - 2 * np.pi * KS * (ta - t0) / N))) ** 2))))
                    for ph, ta in res[1:]]
            hist.append({"k": k, "G_db": 10 * np.log10(G), "ideal_db": 10 * np.log10(ideal), "loss_db": 10 * np.log10(ideal / G),
                         "perr_deg": perr, "dnu_hz": (boards[1].nu(T / FS) + boards[1].nco) - (boards[0].nu(T / FS) + boards[0].nco)})
        # ---------------- new parameters for epoch k + D
        if all(e is not None for e in ests):
            Tk = T + D * period / (1 + eps[0])
            pr, nco = ctl.params(Tk / FS, (Tk + LD) / FS)
            pending[k + D] = (pr, nco)
            for bi in range(2):                         # the anchor schedules the NCO step at the target tick right away
                ctl.nco_change(Tk / FS, bi, nco[bi])
        T += period / (1 + eps[0])
        for b in boards:
            b.advance(T / FS)
    return hist


# oscillator scenarios: offset +-ppm, temperature drift (Hz/s), frequency random walk (Hz/sqrt(s)); the LO phase noise is a Wiener process
# with linewidth lw (Hz): D(tau) = 2 pi lw tau per board. A TCXO multiplied to 2.45 GHz (x61) with about -55 dBc/Hz at 10 Hz offset
# corresponds to lw ~ 0.001 .. 0.01 Hz; TestTask005 E7 measures D(tau) directly.
OSC = dict(ppm=2.0, drift=0.5, rw=0.5)
LW = [0.001, 0.01, 0.03, 0.1, 0.3, 1.0]
SCENARIOS = {"lw_0.001": dict(OSC, lw=0.001), "lw_0.01": dict(OSC, lw=0.01), "lw_0.1": dict(OSC, lw=0.1)}


def summary(h, skip=30):
    h = [x for x in h if x["k"] >= skip]
    if not h:                                   # no lock (soundings not detected)
        return {"loss_db_mean": float("nan"), "loss_db_p95": float("nan"), "G_db_mean": float("nan"), "ideal_db": float("nan"),
                "perr_rms_deg": float("nan"), "perr_p95_deg": float("nan")}
    loss = np.array([x["loss_db"] for x in h]); pe = np.array([x["perr_deg"] for x in h])
    return {"loss_db_mean": float(loss.mean()), "loss_db_p95": float(np.percentile(loss, 95)), "G_db_mean": float(np.mean([x["G_db"] for x in h])),
            "ideal_db": float(h[0]["ideal_db"]), "perr_rms_deg": float(np.sqrt(np.mean(pe ** 2))), "perr_p95_deg": float(np.percentile(np.abs(pe), 95))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--part", default="all", help="all | grid | rest (snr, feedback delay, equal gain, trace)")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "results" / "bf"))
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    seeds = range(3) if not a.quick else range(1)
    ne = 120 if not a.quick else 60

    def avg(**kw):
        s = [summary(run(seed=sd, epochs=ne, **kw)) for sd in seeds]
        return {kk: float(np.mean([x[kk] for x in s])) for kk in s[0]}

    def show(tag, r):
        print(f"{tag:34s} loss {r['loss_db_mean']:.2f} dB (p95 {r['loss_db_p95']:.2f}), phase err {r['perr_rms_deg']:.1f} deg rms "
              f"(p95 {r['perr_p95_deg']:.1f})  [{time.time() - t0:.0f} s]", flush=True)

    prev = out / "bf_loop.json"
    res = json.loads(prev.read_text()) if (a.part != "all" and prev.exists()) else {}
    res.update({"osc": OSC, "slots": SLOTS.tolist(), "ld": LD})
    for k in ("grid", "snr", "delay", "equal_gain"):
        res.setdefault(k, {})
    ep_list = [2.5, 5, 10, 20, 50] if not a.quick else [10]
    lw_list = LW if not a.quick else [0.01]
    for lw in (lw_list if a.part in ("all", "grid") else []):
        for ep in ep_list:
            r = avg(scn=dict(OSC, lw=lw), epoch_ms=ep)
            res["grid"].setdefault(str(lw), {})[str(ep)] = r
            show(f"lw {lw:5.3f} Hz epoch {ep:4.1f} ms", r)
    if not a.quick and a.part in ("all", "rest"):
        for snr in (0, 5, 10, 20, 30):
            res["snr"][str(snr)] = r = avg(scn=dict(OSC, lw=0.01), epoch_ms=10, snr_db=snr); show(f"lw 0.01 epoch 10 SNR {snr} dB", r)
        for D in (1, 2, 3, 5):
            res["delay"][str(D)] = r = avg(scn=dict(OSC, lw=0.01), epoch_ms=10, D=D); show(f"lw 0.01 epoch 10 feedback {D} epochs", r)
        res["equal_gain"] = r = avg(scn=dict(OSC, lw=0.01), epoch_ms=10, mrt=False); show("lw 0.01 epoch 10 equal gain", r)
        res.setdefault("fb_loss", {})
        for ls in (0.1, 0.2, 0.5):
            res["fb_loss"][str(ls)] = r = avg(scn=dict(OSC, lw=0.01), epoch_ms=10, loss=ls); show(f"lw 0.01 epoch 10 feedback loss {ls:.0%}", r)
        res["trace"] = run(dict(OSC, lw=0.01), epochs=150, epoch_ms=10, seed=0)
    (out / "bf_loop.json").write_text(json.dumps(res, indent=1))
    print("->", out / "bf_loop.json")


if __name__ == "__main__":
    main()
