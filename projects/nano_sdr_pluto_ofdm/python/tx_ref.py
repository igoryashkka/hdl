"""TX-chain helpers (golden for phy_ifft_2048 wrapper, phy_tx_scaler, phy_cp_insert)."""
import numpy as np
import fft_ref
from phy_params import IQ_W


def sat16(v):
    return np.clip(v, -(1 << (IQ_W - 1)), (1 << (IQ_W - 1)) - 1)


def ifft_raw(re, im, n_log, mask):
    """IFFT wrapper output in RTL stream (bit-reversed) order, saturated to 16 bit."""
    yr, yi = fft_ref.ifft_fixed(re, im, n_log, IQ_W + 2, mask)
    return sat16(yr), sat16(yi)


def tx_scale(x, gain, frac=14):
    x = np.asarray(x, dtype=np.int64)
    return sat16((x * gain + (1 << (frac - 1))) >> frac)


def cp_insert(raw_re, raw_im, n_log, cp):
    """raw_* : one frame in bit-reversed stream order -> samples of one symbol (cp + body, natural order)."""
    nr, ni = fft_ref.natural(np.asarray(raw_re), np.asarray(raw_im), n_log)
    n = 1 << n_log
    idx = list(range(n - cp, n)) + list(range(n))
    return nr[idx], ni[idx]


def tx_data_symbols(payload):
    """Mapped QAM points per data symbol (complex ints), shape (nsym, NUM_DATA_SC), and the interleaved word list."""
    import scrambler_ref, interleaver_ref, qam_ref
    from phy_params import BYTES_PER_OFDM, NUM_DATA_SC
    nsym = -(-len(payload) // BYTES_PER_OFDM)
    data = list(payload) + [0] * (nsym * BYTES_PER_OFDM - len(payload))
    words = []
    for b in scrambler_ref.scramble(data):
        words += [b >> 4, b & 0xF]
    words = interleaver_ref.interleave(words, 4, 1)
    bits = np.array([[(w >> (3 - k)) & 1 for k in range(4)] for w in words]).reshape(-1)
    iq = qam_ref.map_symbols(bits, order=16)
    return (iq[:, 0] + 1j * iq[:, 1]).reshape(nsym, NUM_DATA_SC), words


def tx_frame(payload, gain=16384, mask=0x0FF, code="none", mode=1):
    """Whole TX chain: bytes -> IQ samples (list of (re, im)), bit-exact model of phy_tx_top.
    code "none": uncoded 16-QAM, 550 bytes per symbol, frame [sync][LTS][data...].
    code "ldpc": dual-mode PHY, frame [sync][LTS][header][data...]; mode 1 = MAX RATE (16-QAM, LDPC 5/6, 450 bytes per symbol),
    mode 0 = MAX RANGE (QPSK, LDPC 1/2, 135 bytes per symbol); the header symbol (QPSK, repetition coded) carries MODE_ID and nsyms."""
    import scrambler_ref, interleaver_ref, qam_ref, ofdm_ref, hdr_ref
    from phy_params import BYTES_PER_OFDM, NUM_DATA_SC, FFT_SIZE, CP_LEN, QPSK_UNIT
    n_log = FFT_SIZE.bit_length() - 1
    hdr_syms = None
    if code == "ldpc":
        import phy2_ref
        bps = phy2_ref.info_bytes_per_sym(mode)
        lay = phy2_ref.layout(mode)
        nsym = -(-len(payload) // bps)
        words = phy2_ref.tx_words(bytes(payload), nsym, "ldpc", mode)
        lay = phy2_ref.layout(mode)
        hb = hdr_ref.tx_bins(lay["id"] if lay["id"] is not None else (0 if lay["mod"] == "qpsk" else 1), nsym)
        hdr_syms = hb[:, 0] + 1j * hb[:, 1]
    else:
        nsym = -(-len(payload) // BYTES_PER_OFDM)
        data = list(payload) + [0] * (nsym * BYTES_PER_OFDM - len(payload))
        sc = scrambler_ref.scramble(data)
        words = []
        for b in sc:
            words += [b >> 4, b & 0xF]
        words = interleaver_ref.interleave(words, 4, 1)
    if code == "ldpc" and lay["mod"] == "qpsk":
        bits = np.array([[(w >> 1) & 1, w & 1] for w in words]).reshape(-1)
        iq = qam_ref.map_symbols(bits, order=4, unit=QPSK_UNIT)
    else:
        bits = np.array([[(w >> (3 - k)) & 1 for k in range(4)] for w in words]).reshape(-1)
        iq = qam_ref.map_symbols(bits, order=16)
    frames = [ofdm_ref.preamble(0), ofdm_ref.preamble(1)]
    if hdr_syms is not None:
        hiq = np.stack([hdr_syms.real, hdr_syms.imag], axis=1).astype(np.int64)
        frames.append(ofdm_ref.insert_pilots(ofdm_ref.map_bins(hiq)))
    for s in range(nsym):
        frames.append(ofdm_ref.insert_pilots(ofdm_ref.map_bins(iq[s * NUM_DATA_SC:(s + 1) * NUM_DATA_SC])))
    out = []
    for fr in frames:
        re = np.array([a for a, b in fr]); im = np.array([b for a, b in fr])
        rr, ri = ifft_raw(re, im, n_log, mask)
        rr, ri = tx_scale(rr, gain), tx_scale(ri, gain)
        cr, ci = cp_insert(rr, ri, n_log, CP_LEN)
        out += [(int(a), int(b)) for a, b in zip(cr, ci)]
    return out
