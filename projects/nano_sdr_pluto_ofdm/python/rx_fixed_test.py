import sys; sys.path.insert(0, '.')
import numpy as np, channel_ref, rx_test, sync_ref, sync_test, rx_blocks_ref as rb, rx_fixed_ref as rf, tx_ref
from phy_params import *

W0_OFF = 104

def run_chain(x, snr, cfo, lead, paths, nsyms, rms=600.0, seed=1, dc=0):
    r = channel_ref.apply_channel(x, snr_db=snr, cfo_hz=cfo, paths=paths, lead=lead, trail=3000, seed=seed)
    i, q = sync_test.adc(r, rms)
    i = i + dc
    di = np.array(rb.dc_remove(i, 12)); dq = np.array(rb.dc_remove(q, 12))
    ev = sync_ref.detect(di, dq)
    if ev is None:
        return None
    inc = sync_ref.cfo_inc(ev["p_re"], ev["p_im"])
    n0 = ev["n_decl"]
    yi, yq = rb.nco_mix(di[n0:], dq[n0:], inc)
    w0 = ev["n_best"] + W0_OFF - n0
    wins = [(yi[w0 + k * SYMBOL_LEN: w0 + k * SYMBOL_LEN + FFT_SIZE], yq[w0 + k * SYMBOL_LEN: w0 + k * SYMBOL_LEN + FFT_SIZE]) for k in range(nsyms + 1)]
    sw, angs = rf.frame_from_windows(wins, nsyms)
    return ev, inc, sw, angs

if __name__ == "__main__":
    pay, x = rx_test.make_frame()
    ref, _ = tx_ref.tx_data_symbols(pay)
    nsyms = ref.shape[0]
    for kw in (dict(snr=35, cfo=0, lead=777, paths=((0, 1),)), dict(snr=30, cfo=9000, lead=1200, paths=((0, 1),)),
               dict(snr=25, cfo=-12000, lead=900, paths=((0, 1), (11, 0.5j))), dict(snr=22, cfo=5000, lead=2000, paths=((0, 1), (6, 0.4), (25, 0.2))),
               dict(snr=18, cfo=-3000, lead=400, paths=((0, 1),)), dict(snr=30, cfo=2000, lead=500, paths=((0, 1),), dc=150)):
        o = run_chain(x, nsyms=nsyms, **kw)
        if o is None:
            print(kw, "NO DETECT"); continue
        ev, inc, sw, angs = o
        got = rf.rx_decode(sw, len(pay))
        err = sum(a != b for a, b in zip(got, pay))
        print({k: v for k, v in kw.items() if k != 'paths'}, "paths", len(kw['paths']), "byte errors:", err, "/", len(pay), "n_best-lead", ev["n_best"] - kw["lead"])
