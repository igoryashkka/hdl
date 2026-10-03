import sys; sys.path.insert(0, '.')
import numpy as np, channel_ref, rx_test, sync_ref
from phy_params import *

def adc(r, rms=600.0):
    r = r * (rms / np.sqrt(np.mean(np.abs(r[np.abs(r) > 0]) ** 2)))
    return np.clip(np.round(r.real), -2048, 2047).astype(np.int64), np.clip(np.round(r.imag), -2048, 2047).astype(np.int64)

if __name__ == "__main__":
    pay, x = rx_test.make_frame()
    rng = np.random.default_rng(3)
    for snr in (30, 15, 8, 5):
        for name, paths in (("flat", ((0, 1),)), ("2path", ((0, 1), (20, 0.6)))):
            offs, epss, miss = [], [], 0
            for t in range(30):
                lead = int(rng.integers(300, 3000)); cfo = rng.uniform(-14000, 14000)
                r = channel_ref.apply_channel(x, snr_db=snr, cfo_hz=cfo, paths=paths, lead=lead, trail=3000, seed=int(rng.integers(1 << 30)))
                i, q = adc(r)
                ev = sync_ref.detect(i, q)
                if ev is None:
                    miss += 1; continue
                offs.append(ev["n_best"] - lead)
                eps = np.angle(complex(ev["p_re"], ev["p_im"])) / np.pi
                epss.append(eps * SUBCARRIER_HZ - cfo)
            o = np.array(offs); e = np.array(epss)
            print(f"snr={snr:2d} {name:5s} miss={miss} n_best-lead min/mean/max={o.min()}/{o.mean():.1f}/{o.max()} std={o.std():.1f}  cfo_err rms={np.sqrt(np.mean(e**2)):.0f} Hz max={np.abs(e).max():.0f}")
