"""RTL TX backend: phy_tx_top simulated with Vivado xsim, controlled and read back by Python."""
from __future__ import annotations

import numpy as np

from ... import refs
from ...core.backend import TxBackend, register_tx
from .simulator import Simulator, XsimError, available


@register_tx("rtl")
class RtlSimTxBackend(TxBackend):
    CLKS_PER_SAMPLE = 2

    def __init__(self):
        self.cfg: dict = {}
        self.packets: list[bytes] = []
        self.debug: dict = {}

    def configure(self, config: dict) -> None:
        self.cfg = config
        if not available(config):
            raise XsimError("Vivado xsim not found (set rtl.vivado_dir or PHYSIM_VIVADO)")

    def send(self, payload: list[bytes]) -> None:
        self.packets = [bytes(p) for p in payload]

    def reset(self) -> None:
        self.packets, self.debug = [], {}

    def get_debug(self) -> dict:
        return self.debug

    def get_iq(self) -> np.ndarray:
        words = []
        lay = refs.phy2_ref.layout(refs.phy_layout(self.cfg)) if refs.phy_code(self.cfg) == "ldpc" else None
        mode_id = 1 if (lay is None or lay["id"] is None or lay["id"] == 1) else 0       # the RTL knows the two standard modes only
        ids = getattr(self, "mode_ids", None)                       # optional per-packet MODE_ID list (mode switching scenarios)
        for k, p in enumerate(self.packets):
            m = mode_id if ids is None else int(ids[k])
            for i, b in enumerate(p):
                words.append(f"{(m << 9) | ((1 if i == len(p) - 1 else 0) << 8) | b:03x}")
        mem = "\n".join(words) + "\n"
        gen = {"CODED": 1 if refs.phy_code(self.cfg) == "ldpc" else 0, "NB": len(words), "NPKT": len(self.packets), "GAIN": int(self.cfg["tx"].get("gain", 16384)),
               "CLKS_PER_SAMPLE": self.CLKS_PER_SAMPLE,
               "PKT_GAP_CLKS": int(self.cfg["experiment"].get("packet_gap", 12000)) * self.CLKS_PER_SAMPLE}
        sim = Simulator(self.cfg)
        text = sim.run("tb_rtl_tx_file", gen, {"rtl_tx_in.mem": mem})["rtl_tx_out.txt"]
        samples, starts, pos, after_gap = [], [], 0, True
        timing, status = {}, {}
        for line in text.splitlines():
            t = line.split()
            if not t:
                continue
            if t[0] == "I":
                v = int(t[1], 16)
                re, im = (v >> 16) & 0xFFFF, v & 0xFFFF
                re = re - 65536 if re >= 32768 else re
                im = im - 65536 if im >= 32768 else im
                if after_gap:
                    starts.append(pos)
                    after_gap = False
                samples.append(complex(re, im)); pos += 1
            elif t[0] == "Z":
                n = int(t[1])
                samples.extend([0j] * n); pos += n
                if n >= 1000:
                    after_gap = True
            elif t[0] == "T":
                timing = {"first_byte": int(t[1]), "last_byte": int(t[2]), "first_iq": int(t[3]), "last_iq": int(t[4]), "total": int(t[5]),
                          "p0_last_byte": int(t[6]) if len(t) > 6 else int(t[2])}
            elif t[0] == "S":
                status = {"underflow": int(t[1]), "overflow": int(t[2]), "pkt_done": int(t[3])}
        nb = sum(len(p) for p in self.packets)
        self.debug = {"packet_starts": starts[:len(self.packets)], "status": status,
                      "perf": {"tx_first_iq_clk": timing.get("first_iq"), "tx_last_byte_clk": timing.get("p0_last_byte"), "tx_first_packet_bytes": len(self.packets[0]) if self.packets else 0,
                               "tx_samples": len(samples), "tx_payload_bytes": nb, "underflow": status.get("underflow"),
                               "overflow": status.get("overflow"), "sim_clks": timing.get("total"),
                               "clks_per_sample": self.CLKS_PER_SAMPLE}}
        return np.array(samples, dtype=complex)
