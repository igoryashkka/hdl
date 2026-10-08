"""Header symbol robustness: CRC failures and wrong MODE_ID of the repetition-coded header (python:fixed model of phy_hdr_dec) vs SNR on AWGN and a 2-path
channel. SNR here is per sample (30.72 MHz band); the symbol-level model uses SNR per bin = SNR per sample + 2.3 dB (1200 of 2048 bins occupied)."""
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))
import hdr_ref  # noqa: E402
import phy2_fixed_ref as F  # noqa: E402
import phy2_ref as P  # noqa: E402
import phy3_test as T3  # noqa: E402
import phy2_test as T  # noqa: E402

OFFSET = 10 * np.log10(2048 / 1200)


def trial(job):
    kind, snr_s, seed = job
    rng = np.random.default_rng(seed)
    T.rng = rng
    H = T.chan(kind)
    snr_bin = snr_s + OFFSET
    sigma2 = np.mean(np.abs(H) ** 2) * P.P_DATA / 10 ** (snr_bin / 10)
    mode = int(rng.integers(0, 2))
    nsy = int(rng.integers(1, 9))
    words = P.tx_words(bytes(rng.integers(0, 256, P.info_bytes_per_sym(mode), dtype=np.uint8)), 1, "ldpc", mode)
    ylts, ys = T3.make_y3(words, mode, H, sigma2, 1, hdr_mode=mode, rng=rng)
    # make_y3 encodes nsyms = 1 in the header; compare with that
    yl, yd = T3._int(ylts, ys)
    _, diag = F.receive_symbols(yl, yd[:1], True, True, True, mode)
    h = diag["hdr"]
    return (kind, snr_s, int(h["ok"]), int(h["ok"] and h["mode"] == mode and h["nsyms"] == 1), int(h["conf"]))


if __name__ == "__main__":
    snrs = list(range(-14, 7, 2))
    jobs = [(k, s, 1000 * i + j) for i, (k, s) in enumerate([(k, s) for k in ("awgn", "2path") for s in snrs]) for j in range(60)]
    with Pool(6) as p:
        res = p.map(trial, jobs, chunksize=4)
    out = {}
    for kind, s, ok, good, conf in res:
        a = out.setdefault(kind, {}).setdefault(s, [0, 0, 0, 0])
        a[0] += 1; a[1] += ok; a[2] += good; a[3] += conf
    rows = {k: [{"snr": s, "n": v[0], "crc_ok": v[1] / v[0], "correct": v[2] / v[0], "conf": v[3] / v[0]} for s, v in sorted(d.items())] for k, d in out.items()}
    Path("results/dualmode").mkdir(parents=True, exist_ok=True)
    Path("results/dualmode/header.json").write_text(json.dumps(rows, indent=1))
    for k, r in rows.items():
        print(k, [(x["snr"], round(x["correct"], 2)) for x in r])
