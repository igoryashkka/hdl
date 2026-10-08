"""Python RX backend.

mode "fixed": the bit-exact fixed-point model of the RTL receiver, built from the existing golden blocks
              (rx_blocks_ref, sync_ref, rx_fixed_ref): input scale -> DC remove -> Schmidl-Cox detector -> CORDIC CFO -> NCO
              -> FFT windows -> FFT -> channel estimate -> equalizer -> CPE tracker -> demap -> deinterleave -> descramble.
mode "float": the floating-point algorithm reference (rx_ref): Schmidl-Cox + CFO + LS channel estimate + equalizer + CPE.
Both modes return the equalised constellation of every packet for EVM / SER analysis."""
from __future__ import annotations

import numpy as np

from .. import refs
from ..core.backend import RxBackend, register_rx

R = refs


@register_rx("python")
class PythonRxBackend(RxBackend):
    def __init__(self):
        self.cfg: dict = {}
        self.payloads: list[bytes] = []
        self.debug: dict = {}

    def configure(self, config: dict) -> None:
        self.cfg = config
        self.nsyms = int(config["payload"]["nsyms"])

    def reset(self) -> None:
        self.payloads, self.debug = [], {}

    # ------------------------------------------------------------------ entry
    def process(self, iq: np.ndarray) -> None:
        self.reset()
        mode = self.cfg["rx"].get("mode", "fixed")
        iq = np.asarray(iq)
        self.debug["sync_metric"] = self._float_sync_metric(iq)
        if mode == "fixed":
            self._process_fixed(iq)
        elif mode == "float":
            self._process_float(iq)
        else:
            raise ValueError(f"unknown python rx mode '{mode}'")

    def get_payload(self) -> list[bytes]:
        return self.payloads

    def get_debug(self) -> dict:
        return self.debug

    # ------------------------------------------------------------------ helpers
    @staticmethod
    def _float_sync_metric(iq: np.ndarray) -> dict:
        r = np.asarray(iq, dtype=np.complex128)
        if len(r) < 3 * R.rx_ref.L:
            return {}
        prod = np.conj(r[:-R.rx_ref.L]) * r[R.rx_ref.L:]
        cs = np.concatenate([[0], np.cumsum(prod)])
        L = R.rx_ref.L
        P = cs[L:] - cs[:-L]
        en = np.abs(r[L:]) ** 2
        ce = np.concatenate([[0], np.cumsum(en)])
        Rr = ce[L:] - ce[:-L]
        n = min(len(P), len(Rr))
        P, Rr = P[:n], Rr[:n]
        return {"P": P, "R": Rr, "M": np.abs(P) ** 2 / np.maximum(Rr, 1e-12) ** 2}

    def _decode_words(self, words_per_sym) -> bytes:
        nbytes = self.nsyms * R.bytes_per_sym(self.cfg)
        return bytes(int(b) for b in R.rx_fixed_ref.rx_decode(words_per_sym, nbytes))

    # ------------------------------------------------------------------ fixed-point (RTL model) receiver
    def _process_fixed(self, iq: np.ndarray) -> None:
        rf, rb, sr, P = R.rx_fixed_ref, R.rx_blocks_ref, R.sync_ref, R.P
        rxc = self.cfg["rx"]
        i = np.round(iq.real).astype(np.int64)
        q = np.round(iq.imag).astype(np.int64)
        sh = int(rxc.get("gain_sh", 0))
        if sh:
            i = np.array(rb.input_scale(i, sh)); q = np.array(rb.input_scale(q, sh))
        k = int(rxc.get("dc_k", 16))
        di = np.array(rb.dc_remove(i, k), dtype=np.int64)
        dq = np.array(rb.dc_remove(q, k), dtype=np.int64)
        events = sr.detect_events(di, dq, hold=int(rxc.get("hold", 9000)), rmin=int(rxc.get("rmin", 262144)))
        self.debug["events"] = []
        self.debug["packets"] = []
        new = R.phy_code(self.cfg) == "ldpc"
        ph = self.cfg.get("phy", {})
        ft_en, tau_tgt = bool(ph.get("fine_timing", True)), int(ph.get("tau_target", 56))
        adj = 0                                                   # fine timing loop state (RTL: w0_adj), carried from packet to packet
        for ev in events:
            inc = int(sr.cfo_inc(ev["p_re"], ev["p_im"]))
            ang = inc - (1 << 32) if inc >= (1 << 31) else inc
            cfo_est = -ang * R.FS / 2 ** 32
            e = {"n_decl": ev["n_decl"], "n_best": ev["n_best"], "cfo_inc": inc, "cfo_hz_est": cfo_est,
                 "sync_start_est": ev["n_best"] - R.SYNC_PEAK_OFFSET}
            self.debug["events"].append(e)
            w0 = ev["n_best"] + R.LTS_WINDOW_OFFSET + (adj if (new and ft_en) else 0)
            e["w0"] = w0
            n0 = min(ev["n_decl"] + 4, w0)             # NCO phase starts a few samples after the detection event
            end = w0 + (self.nsyms + 1) * P.SYMBOL_LEN
            if end - 0 > len(di):
                e["status"] = "truncated"
                continue
            yi, yq = rb.nco_mix(di[n0:], dq[n0:], inc)
            wins = [(yi[w0 - n0 + k2 * P.SYMBOL_LEN: w0 - n0 + k2 * P.SYMBOL_LEN + P.FFT_SIZE],
                     yq[w0 - n0 + k2 * P.SYMBOL_LEN: w0 - n0 + k2 * P.SYMBOL_LEN + P.FFT_SIZE]) for k2 in range(self.nsyms + 1)]
            pk = self._fixed_packet_v2(wins) if R.phy_code(self.cfg) == "ldpc" else self._fixed_packet(wins, rf)
            e["status"] = "ok"
            if new and "tau_q8" in pk:
                e["tau_est"] = pk["tau_q8"] / 256.0
                if ft_en:
                    adj = max(-40, min(40, adj + ((pk["tau_q8"] - tau_tgt * 256) >> 9)))
                e["w0_adj"] = adj
            self.payloads.append(pk["bytes"])
            self.debug["packets"].append(pk)

    def _fixed_packet_v2(self, wins) -> dict:
        """New PHY: LTS channel estimate + guard-bin noise estimate -> MMSE/ZF post engine -> soft LLR -> LDPC (fixed-point models)."""
        F, rf = R.phy2_fixed_ref, R.rx_fixed_ref
        ph = self.cfg.get("phy", {})
        yl = rf.rx_fft(*wins[0])
        yd = [rf.rx_fft(*wins[k]) for k in range(1, self.nsyms + 1)]
        llr, diag = F.receive_symbols(yl, yd, ph.get("eq", "mmse") == "mmse")
        nbytes = self.nsyms * R.bytes_per_sym(self.cfg)
        data, its, done = F.decode_llr(llr, self.nsyms, nbytes, int(ph.get("max_iter", 10)))
        T = np.maximum(np.asarray(diag["T"], float), 1.0)
        eq = np.array([(np.asarray(xr, float) + 1j * np.asarray(xi, float)) * 8192.0 / T for xr, xi in diag["eq"]])
        yr, yi = rf.select_active(*yl)
        mr, mi, E = rf.chest(yr, yi)
        w = (mr.astype(np.float64) + 1j * mi) * 2.0 ** (-E.astype(np.float64))
        tau_q8, _, _ = F.timing_est(yr, yi)
        thr = int(round(float(ph.get("bad_snr_db", 10.0)) / 0.0941))
        avg, mn, bad = F.quality_codes(diag["lgm"], diag["lgnu"], diag["sig_sum"], thr)
        snr_k = np.clip(diag["lgm"] - diag["lgnu"], F.D_MIN, F.D_MAX) * (3.0103 / F.LGF)
        return {"bytes": data, "eq": eq, "angles": np.array(diag["angles"]), "w": w, "H_est": 1.0 / w, "E": E,
                "fft_lts": rf.select_active(*yl), "ldpc_iterations": [int(v) for v in its], "ldpc_failures": int((~done).sum()),
                "ldpc_codewords": int(len(its)), "snr_avg_db": avg * 3.0103 / F.LGF, "snr_min_db": mn * 3.0103 / F.LGF,
                "bad_subcarriers": bad, "snr_k_db": snr_k, "noise_code": int(diag["lgnu"]), "tau_q8": int(tau_q8),
                "sfo_slopes": [int(v) for v in diag["slopes"]], "angles_raw": [int(v) for v in diag["angles"]]}

    def _fixed_packet(self, wins, rf) -> dict:
        yr, yi_ = rf.select_active(*rf.rx_fft(*wins[0]))
        mr, mi, E = rf.chest(yr, yi_)
        words, angs, eq_syms, fft_data = [], [], [], []
        for k in range(1, self.nsyms + 1):
            dr, di_ = rf.select_active(*rf.rx_fft(*wins[k]))
            fft_data.append(dr.astype(np.float64) + 1j * di_)
            xr, xi = rf.equalize(dr, di_, mr, mi, E)
            xr, xi, ang = rf.cpe_track(xr, xi)
            angs.append(int(ang))
            eq = xr[rf.DATA_S].astype(np.float64) + 1j * xi[rf.DATA_S]
            eq_syms.append(eq)
            words.append(rf.demap_deint(xr, xi))
        data = self._decode_words(words)
        w = (mr.astype(np.float64) + 1j * mi) * 2.0 ** (-E.astype(np.float64))
        return {"bytes": data, "eq": np.array(eq_syms), "angles": np.array(angs), "w": w, "H_est": 1.0 / w,
                "fft_lts": rf.select_active(*rf.rx_fft(*wins[0])), "fft_data": np.array(fft_data), "E": E}

    # ------------------------------------------------------------------ floating-point receiver
    def _process_float(self, iq: np.ndarray) -> None:
        rr = R.rx_ref
        r = np.asarray(iq, dtype=np.complex128)
        self.debug["events"], self.debug["packets"] = [], []
        offset = 0
        while len(r) - offset > (self.nsyms + 2) * R.SYM_LEN:
            seg = r[offset:]
            out = rr.receive(seg, self.nsyms)
            if not out.get("ok"):
                break
            e = {"n_best": offset + out["s0"] + R.SYNC_PEAK_OFFSET, "cfo_hz_est": float(out["cfo_hz"]),
                 "sync_start_est": offset + int(out["s0"]), "int_cfo": int(out["int_cfo"]), "status": "ok"}
            self.debug["events"].append(e)
            eq = np.asarray(out["syms"])                     # (nsyms, 1100) in TX constellation units
            re = np.clip(np.round(eq.real), -32768, 32767).astype(np.int64)
            im = np.clip(np.round(eq.imag), -32768, 32767).astype(np.int64)
            words = []
            for k in range(eq.shape[0]):
                pts = np.stack([re[k], im[k]], axis=1)
                llr = R.qam_ref.demap_llr(pts, order=16)
                words.append([sum((int(v) & 0xFF) << (8 * (3 - j)) for j, v in enumerate(row)) for row in llr])
            data = self._decode_words(words)
            self.payloads.append(data)
            H = np.asarray(out["H"])[R.rx_ref.ACTIVE_BINS]
            self.debug["packets"].append({"bytes": data, "eq": eq, "H_est": H, "angles": np.array([])})
            offset += out["s0"] + (self.nsyms + 2) * R.SYM_LEN
