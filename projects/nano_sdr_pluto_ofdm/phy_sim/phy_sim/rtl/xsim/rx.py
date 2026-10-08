"""RTL RX backend: phy_rx_top simulated with Vivado xsim, controlled and read back by Python."""
from __future__ import annotations

import numpy as np

from ... import refs
from ...core.backend import RxBackend, register_rx
from .simulator import Simulator, XsimError, available


@register_rx("rtl")
class RtlSimRxBackend(RxBackend):
    CLKS_PER_SAMPLE = 2

    def __init__(self):
        self.cfg: dict = {}
        self.payloads: list[bytes] = []
        self.debug: dict = {}

    def configure(self, config: dict) -> None:
        self.cfg = config
        self.nsyms = int(config["payload"]["nsyms"])
        if not available(config):
            raise XsimError("Vivado xsim not found (set rtl.vivado_dir or PHYSIM_VIVADO)")

    def reset(self) -> None:
        self.payloads, self.debug = [], {}

    def get_payload(self) -> list[bytes]:
        return self.payloads

    def get_debug(self) -> dict:
        return self.debug

    # ------------------------------------------------------------------
    def process(self, iq: np.ndarray) -> None:
        self.reset()
        iq = np.asarray(iq)
        i = np.clip(np.round(iq.real), -32768, 32767).astype(np.int64) & 0xFFFF
        q = np.clip(np.round(iq.imag), -32768, 32767).astype(np.int64) & 0xFFFF
        mem = "\n".join(f"{(a << 16) | b:08x}" for a, b in zip(i, q)) + "\n"
        rxc = self.cfg["rx"]
        debug = 1 if self.cfg.get("rtl", {}).get("debug", True) else 0
        ph = self.cfg.get("phy", {})
        gen = {"CODED": 1 if refs.phy_code(self.cfg) == "ldpc" else 0, "MMSE": 1 if ph.get("eq", "mmse") == "mmse" else 0, "MAX_ITER": int(ph.get("max_iter", 10)),
               "FT_EN": 1 if ph.get("fine_timing", True) else 0, "TAU_TGT": int(ph.get("tau_target", 56)), "NS": len(iq), "NSYMS": self.nsyms, "RMIN": int(rxc.get("rmin", 262144)), "GAIN_SH": int(rxc.get("gain_sh", 0)),
               "CLKS_PER_SAMPLE": self.CLKS_PER_SAMPLE, "DEBUG": debug}
        sim = Simulator(self.cfg)
        out = sim.run("tb_rtl_rx_file", gen, {"rtl_rx_in.mem": mem})["rtl_rx_out.txt"]
        self._parse(out)

    # ------------------------------------------------------------------
    def _parse(self, text: str) -> None:
        beats, events, incs, q_re, q_im, weights = [], [], [], [], [], {}
        meta, status = {}, {}
        for line in text.splitlines():
            t = line.split()
            if not t:
                continue
            if t[0] == "META":
                meta = {"ns": int(t[1]), "nsyms": int(t[2]), "cps": int(t[3]), "t0": int(t[4])}
            elif t[0] == "B":
                beats.append((int(t[1], 16), int(t[2]), int(t[3])))
            elif t[0] == "E":
                events.append({"n_best": int(t[1]), "n_decl": int(t[2]), "clk": int(t[3])})
            elif t[0] == "C":
                incs.append(int(t[1]) & 0xFFFFFFFF)
            elif t[0] == "Q":
                q_re.append(int(t[1])); q_im.append(int(t[2]))
            elif t[0] == "W":
                weights.setdefault(len(incs), {})[int(t[1])] = int(t[2], 16)
            elif t[0] == "S":
                status = {"det": int(t[1]), "pkt": int(t[2]), "drop": int(t[3]), "wd": int(t[4]), "flags": int(t[5]), "clks": int(t[6]),
                          "cw": int(t[7]) if len(t) > 7 else 0, "cw_fail": int(t[8]) if len(t) > 8 else 0}
        # beats -> packets
        pkts, cur, first_clk = [], [], []
        for data, last, clk in beats:
            if not cur:
                first_clk.append(clk)
            cur.append(data)
            if last:
                pkts.append(cur); cur = []
        self.debug["events"], self.debug["packets"] = [], []
        nsyms = self.nsyms
        q_all = np.array(q_re, float) + 1j * np.array(q_im, float)
        for k, ev in enumerate(events):
            inc = incs[k] if k < len(incs) else 0
            ang = inc - (1 << 32) if inc >= (1 << 31) else inc
            e = {**ev, "cfo_inc": inc, "cfo_hz_est": -ang * refs.FS / 2 ** 32, "sync_start_est": ev["n_best"] - refs.SYNC_PEAK_OFFSET,
                 "status": "ok" if k < len(pkts) else "no_packet"}
            self.debug["events"].append(e)
        perf = {"clks_per_sample": meta.get("cps", 2), "sim_clks": status.get("clks"), "rx_beats": len(beats),
                "rx_drops": status.get("drop", 0)}
        for k, p in enumerate(pkts):
            h0 = p[0]
            nbytes = (h0 >> 16) & 0xFFFF
            flags = (h0 >> 32) & 0xFF
            ver = (h0 >> 40) & 0xFF
            nh = 6 if ver == 3 else 3
            raw = b"".join(int(w).to_bytes(8, "little") for w in p[nh:])[:nbytes]
            self.payloads.append(raw)
            h2 = p[2]
            pk = {"bytes": raw, "flags": flags, "seq": h0 & 0xFFFF, "header": p[:nh], "version": ver,
                  "angle16": (h2 >> 48) & 0xFFFF, "rssi_code": (h2 >> 32) & 0xFFFF, "evm_sum": h2 & 0xFFFFFFFF}
            if ver == 3:
                sg = lambda v, w: v - (1 << w) if v >= (1 << (w - 1)) else v
                b3, b4, b5 = p[3], p[4], p[5]
                k_ = 3.0103 / 32
                pk.update({"snr_avg_db": sg((b3 >> 48) & 0xFFFF, 16) * k_, "snr_min_db": sg((b3 >> 32) & 0xFFFF, 16) * k_,
                           "bad_subcarriers": (b3 >> 16) & 0xFFFF, "noise_code": sg(b3 & 0xFFFF, 16),
                           "ldpc_failures": (b4 >> 56) & 0xFF, "ldpc_iterations": [((b4 >> 32) & 0xFFF) / (2 * nsyms)] * (2 * nsyms), "ldpc_iter_max": (b4 >> 48) & 0x1F,
                           "ldpc_codewords": 2 * nsyms, "tau_q8": sg(b4 & 0xFFFFF, 20), "angle_first": (b5 >> 32) & 0xFFFFFFFF,
                           "sfo_slope_last": sg(b5 & 0xFFFFFFFF, 32)})
            sl = slice(k * nsyms * refs.P.NUM_DATA_SC, (k + 1) * nsyms * refs.P.NUM_DATA_SC)
            if len(q_all) >= sl.stop:
                pk["eq"] = q_all[sl].reshape(nsyms, refs.P.NUM_DATA_SC)
            ang = (p[2] >> 32) & 0xFFFFFFFF
            pk["angles"] = np.array([ang], dtype=np.int64)
            if k + 1 in weights and len(weights[k + 1]) == refs.P.NUM_ACTIVE_SC:
                ws = weights[k + 1]
                w = []
                for s in range(refs.P.NUM_ACTIVE_SC):
                    word = ws[s]
                    mr = (word >> 24) & 0xFFFF; mi = (word >> 8) & 0xFFFF; ex = word & 0xFF
                    mr = mr - 65536 if mr >= 32768 else mr; mi = mi - 65536 if mi >= 32768 else mi
                    ex = ex - 256 if ex >= 128 else ex
                    w.append((mr + 1j * mi) * 2.0 ** (-ex))
                w = np.array(w)
                pk["w"] = w
                pk["H_est"] = 1.0 / np.where(np.abs(w) > 0, w, np.nan)
            self.debug["packets"].append(pk)
            # packet latency: first output beat vs the clock at which the last data window sample was fed
            if k < len(events):
                end_idx = events[k]["n_best"] + refs.LTS_WINDOW_OFFSET + nsyms * refs.SYM_LEN + refs.N_FFT
                last_clk = meta["t0"] + end_idx * meta["cps"]
                perf.setdefault("rx_first_beat_clk", first_clk[k]); perf.setdefault("rx_last_sample_clk", last_clk)
        self.debug["perf"] = perf
        self.debug["status"] = status
