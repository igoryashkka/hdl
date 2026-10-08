"""Symbol-level model of the dual-mode PHY (frequency domain, no time-domain chain): header symbol + data symbols through a channel H and
the fixed-point soft receiver (phy2_fixed_ref).  Used by generate_vectors.py (back-end vectors) and as a quick PER sanity check."""
import sys; sys.path.insert(0, '.')
import numpy as np
import qam_ref, phy2_ref as P, phy2_fixed_ref as F, hdr_ref, ofdm_ref
from phy_params import FFT_SIZE, PILOT_AMP, NUM_DATA_SC, QPSK_UNIT
import phy2_test as T

DS, PS = P._DS, P._PS


def _x_from_pts(pts):
    x = np.zeros(1200, complex)
    x[DS] = pts
    x[PS] = P._pilot_sg() * PILOT_AMP
    return x


def sym_points(words, mode):
    """words (nsym * 1100 interleaved words) -> (nsym, 1100) complex constellation points of the data symbols."""
    lay = P.layout(mode)
    w = np.array(words).reshape(-1)
    if lay["mod"] == "qpsk":
        bits = np.stack([(w >> 1) & 1, w & 1], axis=1).reshape(-1)
        q = qam_ref.map_symbols(bits, order=4, unit=QPSK_UNIT)
    else:
        bits = ((w[:, None] >> np.array([3, 2, 1, 0])) & 1).reshape(-1)
        q = qam_ref.map_symbols(bits, order=16)
    return (q[:, 0] + 1j * q[:, 1]).reshape(-1, NUM_DATA_SC)


def make_y3(words, mode, H, sigma2, nsym, hdr_mode=None, rng=None):
    """-> (ylts, [yhdr, ydata...]) complex 2048-bin FFT outputs with Y = H X + N."""
    rng = rng or T.rng
    hm = (P.layout(mode)["id"] if hdr_mode is None else hdr_mode)
    hb = hdr_ref.tx_bins(hm, nsym)
    frames = [hb[:, 0] + 1j * hb[:, 1]] + list(sym_points(words, mode))
    ys = []
    for pts in frames:
        x = _x_from_pts(pts)
        yf = np.zeros(FFT_SIZE, complex)
        yf[P.ACT] = H * x
        yf += np.sqrt(sigma2 / 2) * (rng.standard_normal(FFT_SIZE) + 1j * rng.standard_normal(FFT_SIZE))
        ys.append(yf)
    ylts = np.zeros(FFT_SIZE, complex)
    ylts[P.ACT] = H * P._lts_sg() * PILOT_AMP
    ylts += np.sqrt(sigma2 / 2) * (rng.standard_normal(FFT_SIZE) + 1j * rng.standard_normal(FFT_SIZE))
    return ylts, ys


def run3(mode, snr, kind, npk=20, nsym=2, mmse=True, iters=10, rng=None, **kw):
    rng = rng or np.random.default_rng(5)
    T.rng = rng
    H = T.chan(kind)
    p_data = P.P_DATA                                    # mean power of 16-QAM; QPSK (2.25 unit) has the same mean power
    sigma2 = np.mean(np.abs(H) ** 2) * p_data / 10 ** (snr / 10)
    lay = P.layout(mode)
    bad, its, hdr_bad = 0, [], 0
    for _ in range(npk):
        nb = lay["bytes"] * nsym
        pay = bytes(rng.integers(0, 256, nb, dtype=np.uint8))
        words = P.tx_words(pay, nsym, "ldpc", mode)
        ylts, ys = make_y3(words, mode, H, sigma2, nsym, rng=rng)
        yl, yd = _int(ylts, ys)
        llr, diag = F.receive_symbols(yl, yd, mmse, True, True, mode, **kw)
        hdr_bad += int(not diag["hdr"]["ok"])
        got, it, ok = F.decode_llr(llr, nsym, nb, iters, mode)
        bad += got != pay
        its.append(it.mean())
    return bad / npk, float(np.mean(its)), hdr_bad


def _int(ylts, ys):
    q = lambda y: (np.clip(np.rint(y.real), -32768, 32767).astype(np.int64), np.clip(np.rint(y.imag), -32768, 32767).astype(np.int64))
    return q(ylts), [q(y) for y in ys]


if __name__ == "__main__":
    for mode, snrs in ((0, (-2, 0, 2, 3, 4, 6, 8)), (1, (12, 14, 15, 16, 18))):
        for kind in ("awgn", "2path"):
            print("mode", mode, kind, [(s,) + run3(mode, s, kind, npk=10) for s in snrs], flush=True)
