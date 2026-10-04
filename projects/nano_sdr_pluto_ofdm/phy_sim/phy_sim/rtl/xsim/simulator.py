"""Vivado xsim driver (RTL simulation backend infrastructure).

The TZ names Verilator + cocotb; this machine has the Vivado simulator, so the RTL is exercised through file-driven
SystemVerilog testbenches (tb/system/tb_rtl_rx_file.sv, tb_rtl_tx_file.sv) that are compiled once (cached by source signature)
and elaborated per run with the experiment parameters as generics. The Python side writes stimulus files and parses the logs,
i.e. Python controls the DUT and the real RTL does all the PHY computation."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import time
from pathlib import Path

from ... import refs

DEFAULT_VIVADO = r"C:\AMDDesignTools\2025.2\Vivado\bin"


def vivado_dir(cfg: dict | None = None) -> Path:
    v = (cfg or {}).get("rtl", {}).get("vivado_dir") or os.environ.get("PHYSIM_VIVADO") or DEFAULT_VIVADO
    return Path(v)


def available(cfg: dict | None = None) -> bool:
    return (vivado_dir(cfg) / "xvlog.bat").exists()


def rtl_files() -> list[Path]:
    root = refs.project_dir()
    files = [root / "rtl" / "common" / "phy_pkg.sv"]
    for d in ("common", "tx", "rx"):
        for f in sorted((root / "rtl" / d).glob("*.sv")):
            if f.name != "phy_pkg.sv":
                files.append(f)
    return files


class XsimError(RuntimeError):
    pass


class Simulator:
    """One compile directory per testbench; every run() elaborates with fresh generics and runs in that directory."""

    def __init__(self, cfg: dict | None = None):
        self.cfg = cfg or {}
        self.vdir = vivado_dir(cfg)
        wd = self.cfg.get("rtl", {}).get("workdir")
        self.root = Path(wd) if wd else refs.project_dir() / "phy_sim" / "results" / "_xsim"
        self.root.mkdir(parents=True, exist_ok=True)
        self.last_log = ""

    # ------------------------------------------------------------------
    def _run(self, exe: str, args: list[str], cwd: Path, log: str) -> str:
        p = subprocess.run([str(self.vdir / f"{exe}.bat"), *args], cwd=str(cwd), capture_output=True, text=True, timeout=3600)
        out = (p.stdout or "") + (p.stderr or "")
        (cwd / f"{log}.log").write_text(out, encoding="utf-8", errors="ignore")
        return out

    def _signature(self, tb: Path) -> str:
        h = hashlib.sha1()
        for f in rtl_files() + [tb]:
            h.update(f.name.encode()); h.update(str(f.stat().st_mtime_ns).encode()); h.update(str(f.stat().st_size).encode())
        return h.hexdigest()[:12]

    def compile(self, tb_name: str) -> Path:
        tb = refs.project_dir() / "tb" / "system" / f"{tb_name}.sv"
        if not tb.exists():
            raise XsimError(f"testbench {tb} not found")
        build = self.root / tb_name
        sig_file = build / "signature.txt"
        sig = self._signature(tb)
        if sig_file.exists() and sig_file.read_text() == sig and (build / "xsim.dir" / "work").exists():
            return build
        if build.exists():
            shutil.rmtree(build, ignore_errors=True)
        build.mkdir(parents=True)
        out = self._run("xvlog", ["-sv", *[str(f) for f in rtl_files()], str(tb)], build, "xvlog")
        if "ERROR" in out:
            raise XsimError("xvlog failed:\n" + "\n".join(l for l in out.splitlines() if "ERROR" in l)[:3000])
        sig_file.write_text(sig)
        return build

    def run(self, tb_name: str, generics: dict, inputs: dict[str, str], timeout_note: str = "") -> dict[str, str]:
        """inputs: {filename: text}. Returns {filename: text} of the files listed in the testbench contract (rtl_*_out.txt)."""
        build = self.compile(tb_name)
        for name, text in inputs.items():
            (build / name).write_text(text, encoding="ascii")
        for f in build.glob("rtl_*_out.txt"):
            f.unlink()
        (build / "xelab.args").write_text("".join(f"-generic_top {k}={v}\n" for k, v in generics.items()), encoding="ascii")
        snap = f"{tb_name}_{int(time.time() * 1000) % 10 ** 9}"
        out = self._run("xelab", ["-debug", "off", "--timescale", "1ns/1ps", "-f", "xelab.args", "-s", snap, tb_name], build, "xelab")
        if "ERROR" in out:
            raise XsimError("xelab failed:\n" + "\n".join(l for l in out.splitlines() if "ERROR" in l)[:3000])
        out = self._run("xsim", [snap, "-runall"], build, "xsim")
        self.last_log = out
        res = {}
        for f in build.glob("rtl_*_out.txt"):
            res[f.name] = f.read_text(encoding="ascii", errors="ignore")
        if not res:
            raise XsimError("simulation produced no output file:\n" + out[-2000:])
        shutil.rmtree(build / "xsim.dir" / snap, ignore_errors=True)
        return res
