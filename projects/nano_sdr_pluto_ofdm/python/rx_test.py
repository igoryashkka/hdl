import sys; sys.path.insert(0, '.')
import numpy as np, tx_ref, channel_ref, rx_ref
from phy_params import *

PAY_LEN = 1100

def make_frame(nbytes=PAY_LEN, seed=5):
    rng = np.random.default_rng(seed)
    pay = [int(v) for v in rng.integers(0, 256, nbytes)]
    iq = tx_ref.tx_frame(pay)
    return pay, np.array([complex(a, b) for a, b in iq])

def evaluate(pay, x, **kw):
    """returns dict with sync results, EVM (dB) and hard-decision symbol error rate vs the transmitted QAM points"""
    ref, _ = tx_ref.tx_data_symbols(pay)
    r = channel_ref.apply_channel(x, **kw)
    o = rx_ref.receive(r, ref.shape[0])
    if not o["ok"]:
        return {"ok": False}
    rx = o["syms"]
    # TX gain scale: time-domain scaling by IFFT shifts (1/256 * 1/16384*gain) -> normalise by best complex gain fit
    g = np.vdot(ref, rx) / np.vdot(ref, ref)
    err = rx - g * ref
    evm = 10 * np.log10(np.mean(np.abs(err) ** 2) / np.mean(np.abs(g * ref) ** 2))
    u = 4096 * abs(g)
    dec = lambda z: np.sign(z.real) * np.where(np.abs(z.real) > 2 * u, 3 * u, u) + 1j * np.sign(z.imag) * np.where(np.abs(z.imag) > 2 * u, 3 * u, u)
    ser = np.mean(np.abs(dec(rx / (g / abs(g))) - abs(g) * ref) > 1e-6 * u)
    return {"ok": True, "cfo_hz": round(o["cfo_hz"], 1), "int": o["int_cfo"], "lts": o["lts_body"], "evm_db": round(float(evm), 1), "ser": float(ser)}

if __name__ == "__main__":
    pay, x = make_frame()
    cases = [dict(snr_db=30, cfo_hz=0, lead=777), dict(snr_db=30, cfo_hz=5000, lead=777), dict(snr_db=30, cfo_hz=-40000, lead=777),
             dict(snr_db=25, cfo_hz=12000, lead=500, paths=((0, 1), (11, 0.5 * np.exp(1j)))), dict(snr_db=15, cfo_hz=3000, lead=100),
             dict(snr_db=25, cfo_hz=48000, lead=3000, paths=((0, 1), (5, 0.4), (20, 0.25j)))]
    for kw in cases:
        print({k: v for k, v in kw.items() if k != "paths"}, "paths" in kw and len(kw["paths"]), evaluate(pay, x, **kw))
