"""Symbol-level comparison of the fixed-point soft receiver (phy2_fixed_ref) with the float reference (phy2_ref)."""
import sys
import numpy as np
import phy2_ref as P
import phy2_fixed_ref as F
import ldpc_ref, ldpc_fixed_ref, scrambler_ref
import phy2_test as T

rng = np.random.default_rng(3)
T.rng = rng


def int_y(ylts, ys):
    q = lambda y: (np.clip(np.rint(y.real), -32768, 32767).astype(np.int64), np.clip(np.rint(y.imag), -32768, 32767).astype(np.int64))
    return q(ylts), [q(y) for y in ys]


def run(snr, kind, mmse, npk=20, nsym=2, llr_scale=1.0, iters=10):
    H = T.chan(kind)
    sigma2 = np.mean(np.abs(H) ** 2) * P.P_DATA / 10 ** (snr / 10)
    bad = 0
    its = []
    for _ in range(npk):
        nb = P.bytes_per_sym("ldpc") * nsym
        pay = bytes(rng.integers(0, 256, nb, dtype=np.uint8))
        words = P.tx_words(pay, nsym, "ldpc")
        ylts, ys = T.make_y(words, H, sigma2, nsym)
        yl, yd = int_y(ylts, ys)
        llr, diag = F.receive_symbols(yl, yd, mmse)
        deint = P.deinterleave_llr(llr.astype(float))
        cw = deint[:, :P.CODED_BITS].reshape(nsym * P.CW_PER_SYM, P.CODE_N)
        hard, it, ok = ldpc_fixed_ref.decode(np.clip(cw, -31, 31).astype(np.int64), iters)
        raw = scrambler_ref.scramble(list(np.packbits(hard[:, :P.CODE_K].reshape(-1))))
        bad += bytes(raw[:nb]) != pay
        its.append(it.mean())
    return bad / npk, float(np.mean(its))


if __name__ == "__main__":
    for kind in ("awgn", "2path"):
        for mmse in (False, True):
            print(kind, "mmse" if mmse else "zf", [(s, run(s, kind, mmse)) for s in (14, 15, 16, 17, 18, 20)], flush=True)
