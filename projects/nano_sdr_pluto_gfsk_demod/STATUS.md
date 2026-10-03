# nano_sdr_pluto_gfsk_demod — стан проєкту

Гілка `GFSK_FPGA_Demod` (HDL і Linux). Оновлено 2026-10-03.
Мета: алгоритм GFSK-приймача (раніше C/Python на ПК і на ARM) перенесено в PL Zynq-7010; у процесорну
систему (PS) йдуть лише декодовані пакети.

## Короткий підсумок

| Етап | Стан |
|---|---|
| RX-тракт AD9361 → PL-демодулятор (один канал, 866.5 МГц) | працює **на залізі** |
| Видалено TX, ILA, IQ-трейс (`cpack`) | зроблено |
| Таймінг після імплементації | закрито: WNS +0.417 нс, TNS 0, WHS +0.013 нс |
| Ресурси Z7010 | LUT 59 % (10 389/17 600), регістри 46 %, BRAM 3 %, **DSP 87.5 % (70/80)** |
| Симуляція (Vivado xsim 2025.2) | пакети 0–5 з `capture_300MB.iq` збігаються з C-декодером байт у байт |
| Linux (dtb) і образ `pluto.frm` | зібрано скриптом `fw/build_frm.sh`, прошито, ядро стартує |
| Читач записів у PS | поки лише `iio_readdev … \| xxd`; постійного читача ще немає |
| Кілька каналів, перевірка пропусків тривог | **не зроблено** |

## Що бачимо на залізі (проміжний результат)

Датчик поруч із Pluto, `GAIN=10`. Приклад запису, що прийшов через DMA в PS:

```
a5 07 0d 00 | 00 00 00 20 | 7c158b92 | 0d 00 00 00 00 00 04 01 1f 04 07 04 00 6a 59 d6
магік, прапорці 07, довжина 13, канал 0 | лічильник пакетів | таймстемп | перші 16 байтів кадру
```
Кадр: довжина 13, `num_sensor` 0, `id_central` 0, номер пакета 260, команда `0x1f` (mc_Alarm), лічильник аварій 4,
зони `07`, поле тривог `04`, CRC8 `6a`, радіо-CRC16 `59d6`. Прапорці `07` означають, що **обидва CRC перевірені в PL**.

Номери пакетів послідовних тривог на цьому каналі: 260, 290, 335, 350. Різниці кратні 15: датчик обходить 15 каналів,
PL слухає один, тож стабільно ловить кожну 15-ту тривогу. Чужі кадри (довжини 15–21) приходять із прапорцями `08`/`10`
і не заважають.

Що це **не** доводить: що тривоги не пропадають. Між запусками `iio_readdev` PL скидає записи (лічильник `drops`),
тож для перевірки пропусків потрібен безперервний читач.

## Архітектура

```
AD9361 RX ─► axi_ad9361 ─► rx_fir_decimator (ADI, обхід при 4.5 MS/s)
                              │ valid / I / Q
                              ▼
        gfsk_rx_pkt_top (rtl/)
          gfsk_nco_mix   NCO + змішувач (канал → 0 Гц)             phase_inc = (fc-LO)/fs·2^32
          gfsk_cic_dec   CIC ÷8, N=3                                4.5 MS/s → 562.5 kS/s
          gfsk_fir       FIR 15 відліків, 150 кГц (дерево суматорів, без DSP-каскаду)
          gfsk_discrim   FM-дискримінатор + вирахування DC
          gfsk_bitsync   відновлення тактової (19.2 кбіт/с, дробовий період)
          gfsk_frame     преамбула + сінк 0x91D3, PN9, збирання байтів
          gfsk_pkt_out   CRC8 + радіо-CRC16, запис 32 байти, AXI-stream 64 біти
                              ▼
                        pkt_dma (axi_dmac, джерело AXI-stream) ─► DDR (HP1) ─► Linux
```

Формат запису (32 байти, 4 слова по 64 біти):

| Байти | Зміст |
|---|---|
| 0 | `0xA5` магік |
| 1 | прапорці: bit0 CRC8 ok, bit1 CRC16 ok, bit2 довжина==13, bit3 кадр >16 байтів, bit4 кадр <16 байтів |
| 2 | байт довжини кадру L |
| 3 | індекс каналу (поки 0) |
| 4–7 | лічильник кадрів, big-endian (зростає і для скинутих записів) |
| 8–11 | лічильник вхідних відліків на початок кадру (4.5 MS/s), big-endian |
| 12–27 | перші 16 байтів кадру після PN9 (довжина … CRC16) |
| 28–31 | нулі |

Правила CRC (з прошивки і C-декодера): CRC8 = XOR байтів 2..12, старт `0x77`, порівнюється з байтом 13.
CRC16: поліном `0x1021`, старт `0x1D0F`, по байтах 0..13, результат XOR `0xFFFF`, big-endian у байтах 14–15.

## Файли

| Шлях | Що |
|---|---|
| `rtl/` | RTL демодулятора (SystemVerilog; обгортка `gfsk_rx_pkt_top.v` — Verilog, бо Vivado не приймає SV як топ модуля-посилання) |
| `system_bd.tcl` | BD: PS7, AD9361, FIR-децимація, `gfsk_rx`, `pkt_dma`; на початку додає RTL у проєкт |
| `system_project.tcl`, `system_top.v`, `system_constr.xdc`, `Makefile` | проєкт (TX-порти прибрано) |
| `sim/` | тестбенчі `tb_gfsk_rx_1ch.sv` (байти кадру) і `tb_pkt_top.sv` (запис на AXI-stream), вектори, `gen_vectors.py` |
| `build_vivado.bat`, `post_reports.tcl` | збірка і звіти |
| `fw/build_frm.sh` | збірка `pluto.frm` (бітстрім з xsa, ядро, dtb, rootfs зі стокового образу) |

Linux (репо `/home/user/linux`, гілка `GFSK_FPGA_Demod`): `zynq-nano-sdr-pluto.dts` перевизначає `tx_dma`,
DDS-ядро і `mwipcore` (видалено), `rx_dma` (джерело AXI-stream, 64 біти) і `adi,digital-interface-tune-skip-mode = <1>`
(без TX не можна налаштувати TX-інтерфейс: інакше `Tuning TX FAILED`, `cf_axi_adc` не проб'ється).

## Команди

Усі шляхи — з кореня `projects/nano_sdr_pluto_gfsk_demod`.

**Симуляція** (потрібні `sim/pkt<k>_iq.txt`: `python sim/gen_vectors.py <capture.iq> <decoded.csv>`):
```
sim\run_sim.bat      # IQ → байти кадру (пакет вибирається в sim\cfg.txt: iq-файл / еталон / phase_inc)
sim\run_pkt.bat      # IQ → запис 32 байти на AXI-stream
```
Еталон `decoded.csv`: `hopdet --file capture.iq --csv decoded.csv` (C-декодер у `hopping_detector/c`).

**Збірка Vivado** (ADI-скрипти вимагають 2025.1, встановлено 2025.2, тому в bat задано `ADI_IGNORE_VERSION_CHECK=1`):
```
build_vivado.bat                 # BD, синтез, імплементація, бітстрім (~15 хв)
vivado -mode batch -source post_reports.tcl   # reports_timing.rpt, reports_util*.rpt з routed.dcp
```
Не запускати два білди одночасно: вони псують спільну папку `.runs`.

**Образ і прошивка** (WSL):
```
fw/build_frm.sh path/to/system_top_xxx.xsa     # → /root/fw/pluto.frm
```
Скрипт: розпаковує `.bit` з xsa, бере rootfs зі стокового `pluto.frm` v0.38, збирає ядро
(`zynq_nano_sdr_pluto_defconfig`, `zImage UIMAGE_LOADADDR=0x8000`) і `zynq-nano-sdr-pluto.dtb`,
пише `pluto.its` (magic `ITB PlutoSDR (ADALM-PLUTO)`, FPGA на 0xF000000, ядро на 0x8000), `mkimage`, додає md5.
Прошивка: скопіювати `pluto.frm` на диск PlutoSDR, Eject, чекати перезапуску. FSBL і U-Boot лишаються вендорські.

**Перевірка на Pluto:**
```
dmesg | grep -i -E "ad9361|axi-dmac|cf_axi|dds"
echo 4500000   > /sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency
echo 867400000 > /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency
echo manual    > /sys/bus/iio/devices/iio:device0/in_voltage0_gain_control_mode
echo 10        > /sys/bus/iio/devices/iio:device0/in_voltage0_hardwaregain
iio_readdev -T 90000 -b 8 -s 2000 cf-ad9361-lpc voltage0 voltage1 | xxd -c 32 | grep " a507 "   # лише валідні тривоги
```
(8 відліків × 4 байти = один запис; усі запити DMA — по 32 байти.)

## Відомі обмеження і відкриті питання

- **Один канал** (866.5 МГц, `phase_inc = 0xCCCCCCCD`), ~1 з 15 тривог видно. Банк із 15 каналів — окремий етап.
- **DSP 87.5 %**: на цьому тракті більше каналів не поміститься, доки не зменшити використання (симетричний FIR,
  поділ множників у часі). Потреби зараз немає.
- **Запас таймінгу малий** (WNS +0.417 нс): після кожної зміни RTL перевіряти звіти.
- **`MODE_1R1T 0`** (2R2T) у BD, а плата Rev.C працює як 1R1T; на залізі це не завадило, але не з'ясовано.
- Збірка обходить перевірку версії Vivado (2025.2 замість 2025.1).
- Постійний читач записів у PS (перевірка пропусків, послідовності лічильників) не написаний.
- Генерація xsa ще ручна (через GUI/`build_vivado.bat` без експорту); `fw/build_frm.sh` приймає готовий xsa.
- Вхідні дані симуляції (6 пакетів) — з одного запису, чужі кадри та брудний ефір на RTL не перевірялись у симуляції.
