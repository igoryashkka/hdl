"""Statistics of coarse timing (no LTS correlation) and end-to-end quality: window start = s0_est + SYM + CP - BACK_OFF."""
import sys; sys.path.insert(0, '.')
import numpy as np, tx_ref, channel_ref, rx_ref
from phy_params import *
import rx_test

def coarse_err(x, trials, snr, paths, cfo_range, seed=0):
    rng = np.random.default_rng(seed); errs = []
    for t in range(trials):
        lead = int(rng.integers(200, 3000)); cfo = rng.uniform(-cfo_range, cfo_range)
        r = channel_ref.apply_channel(x, snr_db=snr, cfo_hz=cfo, paths=paths, lead=lead, seed=int(rng.integers(1 << 30)))
        s0, Pc = rx_ref.detect(r)
        errs.append(None if s0 is None else s0 - lead)
    return errs

if __name__ == "__main__":
    pay, x = rx_test.make_frame()
    for snr in (30, 20, 12, 8):
        for name, paths in (("flat", ((0, 1),)), ("2path", ((0, 1), (20, 0.6))), ("3path", ((0, 1), (15, 0.5j), (40, 0.3)))):
            e = coarse_err(x, 40, snr, paths, 40000)
            miss = sum(v is None for v in e); v = np.array([a for a in e if a is not None])
            print(f"snr={snr:2d} {name:5s} miss={miss:2d} err min/mean/max = {v.min():4d}/{v.mean():6.1f}/{v.max():4d}  std={v.std():5.1f}")
