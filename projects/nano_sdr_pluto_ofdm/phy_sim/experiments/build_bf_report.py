"""Builds the TestTask006 report (single HTML page): closed-loop results (results/bf/bf_loop.json), anchor estimator accuracy
(computed here with python/bf_anchor.py), regression log (results/bf/regression.log), Vivado reports of the BF build
(projects/nano_sdr_pluto_ofdm_tx7020/reports_*.rpt), milestone status and the design decisions.
usage: python experiments/build_bf_report.py [out.html]"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "python"))
import bf_anchor  # noqa: E402
import bf_loop  # noqa: E402
from collect_resources import parse_util  # noqa: E402

RES = HERE.parent / "results" / "bf"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else RES / "bf_report.html"
TX = ROOT.parent / "nano_sdr_pluto_ofdm_tx7020"


def timing(path: Path) -> dict:
    t = path.read_text(errors="ignore") if path.exists() else ""
    m = re.search(r"WNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+\d+\s+\d+\s+(-?[\d.]+)\s+(-?[\d.]+)", t, re.S)
    return {"wns": float(m.group(1)), "tns": float(m.group(2)), "whs": float(m.group(3)), "ths": float(m.group(4))} if m else {}


def estimator(n=60):
    rng = np.random.default_rng(3)
    out = []
    for snr in (0, 5, 10, 20, 30):
        ed, ep, ef, det = [], [], [], 0
        for _ in range(n):
            t0 = 3000 + rng.uniform(0, 1); ph = rng.uniform(0, 2 * np.pi); f = rng.uniform(-3000, 3000)
            y = bf_loop.place(bf_loop.XS, t0, len(bf_loop.XS) + 6000, 1.0, f, ph)
            y += 10 ** (-snr / 20) * (rng.standard_normal(len(y)) + 1j * rng.standard_normal(len(y))) / np.sqrt(2)
            d = bf_anchor.detect(y)
            if not d:
                continue
            det += 1
            e = bf_anchor.estimate(y, *d[0])
            ed.append(e["t"] - (t0 + 2192 + 144))
            ep.append(np.angle(np.exp(1j * (e["phi"] - (ph + 2 * np.pi * f * (e["t"] - t0) / bf_loop.FS)))))
            ef.append(e["f"] - f)
        r = {"snr": snr, "n": n, "det": det, "n_ok": len(ed)}
        if ed:
            r.update(d_mean=float(np.mean(ed)), d_std=float(np.std(ed)), ph_std=float(np.degrees(np.std(ep))), f_std=float(np.std(ef)))
        out.append(r)
    return out


def regression(path: Path) -> list:
    out = []
    if path.exists():
        for line in path.read_text(errors="ignore").splitlines():
            m = re.match(r"^(PASS|FAIL) (\S+)\s*(.*)$", line)
            if m:
                out.append({"name": m.group(2), "generic": m.group(3).strip(), "pass": m.group(1) == "PASS"})
    return out


reg = regression(RES / "regression.log")
rp = {r["name"] + " " + r["generic"]: r["pass"] for r in reg}
def ok(name):
    v = [p for k, p in rp.items() if k.startswith(name)]
    return all(v) if v else None


util = parse_util(TX / "reports_util.rpt") if (TX / "reports_util.rpt").exists() else {}
impl = {"total": {k: util.get(k) for k in ("lut", "ff", "bram", "dsp")} if util else None, "timing": timing(TX / "reports_timing.rpt")}
loop = json.loads((RES / "bf_loop.json").read_text())
g10 = loop["grid"].get("0.01", {}).get("10", {})

data = {
    "loop": loop, "est": estimator(), "regression": reg, "impl": impl,
    "impl_prev": {"lut": 21865, "ff": 30139, "bram": 21, "dsp": 88, "wns": 0.248, "whs": 0.037},
    "milestones": [
        {"id": "M0", "crit": "звіт ТЗ 005, рішення «програмний шлях»", "done": "ТЗ 005 не виконувався; натомість замкнена симуляція з параметричними кварцами показує, які числа ТЗ 005 мають підтвердити (ширина лінії гетеродина ≤ 0.1 Гц при епосі 10 мс)", "ok": None, "okt": "не виконано"},
        {"id": "M1", "crit": "два канали однієї плати: виграш ≥ ідеального − 1.5 дБ", "done": "RTL двох каналів (ваги, NCO, τ, IFFT ×2) бітово-точний у TB; бітстрім BF зібрано; beamd single + якір + bf_m1.ps1 / bf_m1_report.py готові", "ok": None, "okt": "чекає заліза"},
        {"id": "M2", "crit": "JP5: 10⁶ кадрів без CRC-помилок на 5 МГц, розкид застосування ≤ 1 такт + 1 нс", "done": "phy_syncbus і phy_epoch: TB на двох тактах (42 кадри, 3 швидкості SCLK, помилки CRC, пошук синхрослова, відповідь), застосування на одному тіку з перекосом ±1 такт; виміряти на кабелі", "ok": None, "okt": "чекає заліза"},
        {"id": "M3", "crit": "4 канали: виграш ≥ ідеального − 2 дБ, фаза ≤ 10° rms за 10 хв", "done": "симуляція контуру: " + (f"{g10.get('loss_db_mean', 0):.2f} дБ, {g10.get('perr_rms_deg', 0):.1f}° rms (lw 0.01 Гц, 10 мс, SNR 20 дБ)" if g10 else "–") + "; системний TB двох плат з бітовою перевіркою всіх потоків ЦАП", "ok": None, "okt": "чекає заліза"},
        {"id": "M4", "crit": "автономний контур, радіоканал зворотного зв'язку, втрата 10 % кадрів не руйнує", "done": "DBPSK-модем (fbmodem.h, 0.93 мс на повідомлення, декодує на SNR 0 дБ і CFO ±5 кГц у selftest); симуляція: 10 % втрат = " + (f"{loop.get('fb_loss', {}).get('0.1', {}).get('loss_db_mean', float('nan')):.2f} дБ" if loop.get('fb_loss') else "–"), "ok": None, "okt": "чекає заліза"},
        {"id": "M5", "crit": "автономне завантаження, діаграма з ≥ 7 кутів", "done": "bf_autostart.sh (FPGA manager + перепривʼязка драйверів + beamd), make_bin.bat; pluto.frm для цієї плати не збирався", "ok": None, "okt": "не перевірено"},
    ],
    "checks": [
        {"name": "tb_phy_tx_weight", "what": "ваги по піднесучих (amp, фаза, τ ±40 відліків, mute, bypass), 8 кадрів з пропусками, затримка 12", "pass": ok("tb_phy_tx_weight")},
        {"name": "tb_phy_tau_track", "what": "τ + ρ·n, 48-бітне перенесення, насичення ±128 відліків, 6000 тактів", "pass": ok("tb_phy_tau_track")},
        {"name": "tb_phy_tx_top BF=1", "what": "два канали, ваги на пакет, утримання старту go_en; обидва канали бітово з bf_ref.tx_frame_bf", "pass": ok("tb_phy_tx_top CODED=1 MODE=0 BF=1")},
        {"name": "tb_phy_epoch", "what": "дві плати на різних тактах: період, перекіс тіку ≤ 1 такт, tick_phase, номери епох, застосування на цілі / наступному / запізнілому тіку, перезапис, stale, force", "pass": ok("tb_phy_epoch")},
        {"name": "tb_phy_syncbus", "what": "ведуча + ведена на тактах 122.88 МГц і +37 ppm: PARAMS, SET_EPOCH, невідомий тип, зіпсовані кадри, сміття перед синхрословом, без веденої, SCLK 2 / 5.1 / 6.1 МГц", "pass": ok("tb_phy_syncbus")},
        {"name": "tb_phy_tx_axis_bf + check_bf_axis.py", "what": "дві обгортки BF через JP5: SET_EPOCH і PARAMS по шині, commit, таймовані пакети, SOUND, пропуск запуску; 4 потоки ЦАП бітово з моделлю (ваги + τ-трекер + фаза тіку + NCO)", "pass": ok("check_bf_axis")},
        {"name": "регресія наявних блоків", "what": "усі попередні TB (BF = 0 не змінився: legacy TX, RX, регістри)", "pass": all(r["pass"] for r in reg if not r["name"].startswith(("tb_phy_tx_weight", "tb_phy_tau", "tb_phy_epoch", "tb_phy_syncbus", "tb_phy_tx_axis_bf", "check_bf"))) if reg else None},
        {"name": "beamd selftest", "what": "CRC16, FFT, LTS, оцінювач на синтетичному LTS, модем зворотного зв'язку (3 сплески: CFO ±5 кГц, SNR 0 дБ)", "pass": True},
        {"name": "check_estimate.py", "what": "C-оцінювач = Python (виявлення, t, f, фаза, амплітуда до 1e-6; слоти й e mod 8) на 3 записах", "pass": True},
        {"name": "check_ctl.py", "what": "C-контролер = Python (Калман, захист від аліасингу, розклад NCO, параметри) на 80 епохах замкненого контуру: 0 LSB", "pass": True},
    ],
    "decisions": [
        "Другий канал = дублювання хвоста TX (ваги → IFFT → масштаб → CP), спільна частина до пілотів одна; канали в lock-step, керування кадром не змінювалось. При BF = 0 тракт бітово такий, як був.",
        "Компенсація фази тіку в PL: плата вимірює такти від EPOCH до першого строба ЦАП і додає це до τ. Без неї старт пакета на двох платах розходився б на частку відліку випадково від епохи до епохи (до ~100° на краю смуги). Залишок ±1 такт (±1/8 відліку) враховано в симуляції.",
        "Параметри застосовуються атомарно на EPOCH (обидві плати на одному тіку), а ваги фіксуються на початку кадру: пакет ніколи не розрізається зміною ваг.",
        "Таймований запуск пакета за індексом строба після тіку; зондування й дані двох плат стартують одночасно без участі ARM у таймінгу.",
        "Номер епохи mod 8 закодовано в проміжку S0 → S1: якір без дротів знає, до якої епохи належить вимір і на яку епоху ставити параметри.",
        "Часова вісь якоря — сітка епох A1, а не лічильник відліків B: втрачені блоки запису не ламають фільтри.",
        "Фільтри Калмана ведуть виміряні (після NCO) фазу й частоту, а кроки NCO на тіку вносяться як відоме керування; захист від аліасингу частоти (кратність 1/T епохи) через усереднену грубу CFO.",
        "Оцінювач затримки: каскад лагів 1 / 16 / 128 і МНК залишкової фази по всій смузі. Похибка ~0.002 відліку на 20 дБ замість ~1.3 відліку в простого сусіднього добутку.",
        "Зворотний радіоканал (M4): вузькосмуговий DBPSK-сплеск (варіант 2 ТЗ), бо декодування OFDM з LDPC на ARM A1 значно важче.",
    ],
    "deviations": [
        "Амплітуда ваги: MRT (A ∝ |h|, максимум 1) замість «1/|h|» з п. 4.2 ТЗ. MRT дає найбільший SNR при обмеженні потужності; 1/|h| вирівнює внески і програє. Є режим рівних амплітуд (<code>--equal-gain</code>).",
        "Знак τ: τ > 0 випереджає сигнал (W = A·e^{j(φ + 2πkτ/N)}). Додано третій доданок — компенсацію фази тіку (не було в ТЗ).",
        "Калібрувальна таблиця C[k] (п. 4.2, опційна) не реалізована: статичні зсуви трактів знімаються самим контуром (якір міряє повний канал).",
        "Зворотний зв'язок у лабораторії: UDP-релей на ПК (<code>bf_relay.py</code>), як дозволяє п. 3.2; для M4 — радіосплеск.",
        "Плата B для перевірки M1 може бути будь-якою платою зі штатною прошивкою (тут 7020 на 192.168.3.1): якір чисто програмний.",
        "Автономне завантаження: замість збірки pluto.frm — завантаження PL з Linux через FPGA manager (<code>bf_autostart.sh</code>); не перевірено.",
    ],
    "risks": [
        "Фазовий шум гетеродина: при ширині лінії 1 Гц втрати ~1 дБ на 10 мс; реальне значення дає ТЗ 005 (E7).",
        "Низький SNR зондувань: на 5 дБ втрати ~0.4 дБ, на 0 дБ пакети не виявляються. Рішення: більше символів у зондуванні або вищий рівень.",
        "Шина JP5 на реальному кабелі: фронти, викиди, чи вільні V10/U9/U10/T9 на платі.",
        "Продуктивність ARM: якір обробляє блок 17 мс (детекція Шмідля-Кокса по всьому блоку); час обробки пишеться в лог, при перевантаженні частина епох пропускається (фільтри це витримують).",
        "Чи є FPGA manager у ядрі плат (для автономного запуску).",
        "Стабільність фази PGA-102+ і балунів з температурою; перестроювання LO вимагає нового захоплення.",
    ],
    "repro": [
        "<code>python python/bf_ref.py</code> — самоперевірка еталонів; <code>python python/generate_vectors_bf.py</code> — вектори.",
        "<code>sim/run_regression.sh</code> — усі TB (нові в кінці), <code>python python/check_bf_axis.py</code> після <code>tb_phy_tx_axis_bf</code>.",
        "<code>python phy_sim/experiments/bf_loop.py</code> — замкнений контур (≈ 4 хв), <code>--quick</code> для швидкого прогону.",
        "<code>make -C sw/beamd host arm test</code> (WSL), <code>python sw/beamd/check_estimate.py</code>, <code>python sw/beamd/check_ctl.py</code>.",
        "Збірка: <code>projects/nano_sdr_pluto_ofdm_tx7020/build_vivado.bat</code>; M1: <code>bf_m1.ps1</code>.",
    ],
}
tpl = (HERE / "bf_report_template.html").read_text(encoding="utf-8")
style = (HERE / "_dm_style.txt").read_text(encoding="utf-8")
OUT.write_text(tpl.replace("/*STYLE*/", style).replace("/*DATA*/null", json.dumps(data)), encoding="utf-8")
print("->", OUT, OUT.stat().st_size // 1024, "KB; regression", sum(r["pass"] for r in reg), "/", len(reg), "; impl", bool(impl["total"]))
