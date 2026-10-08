# nano_sdr_pluto_ofdm — Long-Range Video PHY (OFDM, 16-QAM, LDPC)

> **Гілка `OFDM_PHY_Z7020`: Design not targeted for Zynq-7010.** Нова платформа Zynq-7020 (xc7z020clg400-1), сумісність із Z7010 не зберігається. ТЗ: `../nano_sdr_pluto/TestTask_7020.md` (LDPC R=5/6 + soft LLR, MMSE, fine timing + CFO/SFO tracking, SNR-estimator; simulation-first).

Гілка `OFDM_PHY` (Z7010, uncoded) лишається як "Current PHY" для порівняння. ТЗ: `../nano_sdr_pluto/TestTask.md`, правила розробки: `../nano_sdr_pluto/CLAUDE.md`.
## Структура: спільне ядро + два білди
```
nano_sdr_pluto_ofdm/      спільне: rtl/ tb/ python/ sim/ (цей каталог, не Vivado-проєкт)
nano_sdr_pluto_ofdm_tx/   TX-only білд: PS -> DMA(mem->stream) -> PHY TX -> AD9361 DAC     (0x7C420000, irq 12)
nano_sdr_pluto_ofdm_rx/   RX-only білд: AD9361 ADC -> PHY RX -> DMA(stream->mem) -> PS    (0x7C400000, irq 13)
```
Весь фізичний рівень у PL; у PS іде лише потік пакетів через DMA (64-біт AXI-stream), пакетайзер/логер — програма на C (`sw/plutolink`).
Жодного IQ по USB. Обидва білди згенеровані з `../nano_sdr_pluto` викиданням зайвого (FIR, ILA, cpack, ADC/DAC DMA, TX/RX піни де можливо).
У TX-only лишаються RX-піни (rx_clk_in/frame/data): `l_clk` ядра axi_ad9361 береться з DATA_CLK мікросхеми.
Обидва білди мають AXI-Lite блок керування/логування `phy_regs_axil` на `0x7C440000` (див. "Bring-up").
Збірка: `nano_sdr_pluto_ofdm_{rx,tx}/build_vivado.bat` (Vivado 2025.2). На залізі ще не перевірено.

## Нумерологія (`rtl/common/phy_pkg.sv` ↔ `python/phy_params.py`)
30.72 MSPS, FFT 2048, df = 15 кГц, CP 144 (символ 2192 відліки, ≈14.01 ксимв/с), 1200 активних піднесучих,
пілот кожна 12-та → 100 пілотів + 1100 даних, 16-QAM → 4400 кодованих біт/OFDM-символ (≈61.7 Мбіт/с),
LDPC R=5/6 → ≈51 Мбіт/с до накладних витрат (преамбула/пілот-символи) — підтвердити після появи кадру.

## Блоки: статус
| Блок | RTL | Python golden | TB (self-check) | Latency (цикли) |
|---|---|---|---|---|
| phy_scrambler / descrambler | ✅ | ✅ bit-exact | ✅ | 1 |
| phy_crc (CRC-32) | ✅ | ✅ | ✅ | 1 |
| phy_qam_mapper (4/16/64) | ✅ | ✅ | ✅ | 1 |
| phy_qam_demapper (max-log LLR) | ✅ | ✅ | ✅ | 2 |
| phy_interleaver / deinterleaver (символьний, ping-pong) | ✅ | ✅ | ✅ backpressure | store&forward: блок 1100 слів |
| phy_ofdm_mapper + phy_pilot_insert | ✅ | ✅ | ✅ | 1 + 1 |
| phy_preamble_gen (sync + LTS) | ✅ | ✅ | ✅ | 2 від start |
| phy_fft_core (R2SDF, 2^N, DSP 4/ступінь D>=4) + phy_ifft_2048 | ✅ | ✅ bit-exact (N=16/64/2048, saturation) | ✅ gaps/reset/latency | 2105 (N=2048) |
| phy_tx_scaler | ✅ | ✅ | ✅ | 2 |
| phy_cp_insert (bit-reverse + CP, 3 банки) | ✅ | ✅ | ✅ | буфер |
| phy_tx_frame_ctrl + phy_tx_top | ✅ | ✅ (tx_ref.tx_frame) | ✅ system, 17536 відліків bit-exact, без розривів | — |
| LDPC enc/dec | ❌ | ❌ | ❌ | |
| phy_dc_remove, phy_input_scale (AGC gain) | ✅ | ✅ | ✅ | 1 |
| phy_sync_sc (Schmidl-Cox: детекція, груба синхронізація, P для CFO; 6 DSP) | ✅ | ✅ sync_ref.detect bit-exact | ✅ подія/без події/шум, gaps, reset | ~12 від TRACK_LEN-го відліку |
| phy_cordic (векторинг, ітеративний) + phy_cfo_coarse (P -> приріст фази NCO) | ✅ | ✅ | ✅ | 25 / 28 |
| phy_nco_mixer (32-біт NCO, 1024-табл., комплексний міксер) | ✅ | ✅ | ✅ | 7 |
| phy_rx_window (вікна FFT, flush темпом семплів) | ✅ | модель у TB | ✅ | 1 |
| phy_fft_2048/phy_rx_fft (FFT + реордер, NB=2) | ✅ | ✅ rx_fft bit-exact | ✅ + core_rst, 2 проходи | 2114+ |
| phy_bin_select, phy_channel_estimator (1/x: таблиця + Ньютон), phy_equalizer | ✅ | ✅ chest/equalize bit-exact | ✅ | 1 / 18 / 7 |
| phy_phase_tracker (CPE з пілотів, CORDIC) | ✅ | ✅ cpe_track bit-exact | ✅ | ~45 від in_last |
| phy_rx_decode (демапер, деінтерлівер, жорсткі біти, дескремблер), phy_rx_pkt_out (запис DMA) | ✅ | ✅ decode_symbols | ✅ | — |
| phy_rx_top + контролер (системний TB: 2 пакети, CFO +9/-7 кГц, багатопроменевість, 0 помилок байтів) | ✅ | ✅ cfo_inc/n_best bit-exact | ✅ system | — |
| System TB + channel model (AWGN/CFO/multipath/Doppler) | ✅ `phy_sim/` | | | |
| phy_regs_axil (AXI-Lite, 2 клок-домени, snapshot) + обгортки RX/TX | ✅ | — | ✅ `tb_phy_regs_axil`, `tb_phy_rx_axis_top`, `tb_phy_tx_axis_top` | — |
| phy_rssi_code, EVM-сума з пілотів (phase_tracker `l1_val`), `ev_r` у sync_sc | ✅ | ✅ `rssi_code`, `cpe_track_l1`, `r_best` | ✅ | — |

Vivado TX-only (із реальним phy_tx_top): LUT 3461, FF 2220, BRAM 9xRAMB36+16xRAMB18, DSP 39; таймінг на l_clk (rx_clk 8 нс, 2R2T = 122.88 МГц):
WNS +0.458 / TNS 0 / WHS +0.009 / THS 0, бітстрім і xsa зібрано. На залізі ще не перевірено.

## TX: правила таймінгу (важливо для RX і майбутніх змін)
* SDF-IFFT віддає кадр i від кінця подачі кадру i до кінця подачі i+1 -> для безперервного відтворення потрібно **3 банки** у phy_cp_insert,
  а контролер стартує символ i, лише коли (i - відтворено) <= NB-1.
* Після останнього символу подається N-1 нулів (flush), далі програмне скидання ядра FFT (вирівнює лічильники ступенів).
* Інтерлівер/CP-буфер: читання лише синхронне в регістр без логіки (інакше Vivado робить LUTRAM замість BRAM — це з'їло 4800 LUT).
* Затримка phy_complex_mult = 4 (інакше постсума не закриває 8 нс).

## Запуск тестів
```
sim/run_regression.sh            # генерує вектори python/generate_vectors.py і проганяє всі TB (xsim 2025.2)
GENERIC=ORDER=16 sim/run_tb.sh tb_phy_qam_demapper
```
Конвенції: стимул — `{last,first,valid,payload}` на такт з випадковими паузами (сміття на idle-тактах);
latency перевіряється точно (`out_valid == in_valid` затриманий на LATENCY); LLR>0 ⇒ біт 0.

## RX: архітектура (за Python-референсом `python/rx_ref.py`, `rx_test.py`, `rx_sweep.py`)
Перевірено у float: CFO до +-48 кГц (похибка < 10 Гц), 1/2/3-променеві канали, SNR 8..30 дБ, EVM ~ SNR.
Конвеєр RX: input scale/DC -> Schmidl-Cox (лаг 1024: P, R, M) -> детекція/плато -> фракційний CFO (phase_inc = angle(P)/1024)
-> NCO+міксер -> ціле CFO (диференціальна кореляція спектра sync-символу) -> **вікно FFT = груба оцінка + SYM + CP - 48**
(**без LTS-кореляції**: залишок таймінгу = лінійна фаза в H; груба похибка -3..+20 відліків при 8 дБ < CP-48-розкид)
-> FFT 2048 + реордер -> LS-оцінка каналу з LTS (H = Y*sign(LTS)/A, без ділення) -> w = conj(H)/|H|^2 (конвеєрний 1/x)
-> еквалайзер X = Y*w -> CPE з 100 пілотів -> демапер -> деінтерлівер -> дескремблер -> пакет у DMA.
Статус RX RTL: повний ланцюжок у PL, bit-exact проти Python-моделі (див. таблицю вище).

## Vivado (Z7010, l_clk 8 нс = 125 МГц): обидва білди закриті
| Білд | WNS | TNS | WHS | THS | DSP | BRAM | FF |
|---|---|---|---|---|---|---|---|
| TX-only (v0.3.0, з регістрами) | +0.521 | 0 | +0.012 | 0 | 55/80 | 20 | 19021 |
| RX-only (v0.3.0, з регістрами, DDS/IQ-корекція DAC вимкнені в axi_ad9361) | +0.375 | 0 | +0.011 | 0 | 67/80 | 30 | 16621 |
Весь проєкт (з платформою AD9361/DMA/PS): TX LUT 13264 (75 %); RX LUT 13148 (75 %), slice 98.9 %, DSP 84 %. Запасу під LDPC на Z010 немає.
RX-білд: у `axi_ad9361` вимкнено DDS і IQ-корекцію DAC (`DAC_DDS_DISABLE`, `DAC_IQCORRECTION_DISABLE`) — звільнило ≈2k LUT, без цього регістровий блок не вміщався.
Ресурси самого PHY RX ≈ 9.2k LUT / 62 DSP (до оптимізації еквалайзера). Подальші економії: радикс-2^2 FFT / 3-множникове комплексне множення.
Формат пакета для DMA — у `rtl/rx/phy_rx_pkt_out.sv` (3 заголовкові beat'и + payload, tlast).

## Bring-up на залізі (v0.3.0): логування, регістри, `plutolink`
* **Запис пакета v2** (`phy_rx_pkt_out`): beat0 `{A55A, 02, flags, nbytes, seq}`, beat1 `{cfo_inc, n_best}`, beat2 `{angle16, rssi16, evm32}`
  (rssi = log2-код енергії вікна S-C, evm = сума L1-похибок пілотів після еквалайзера і CPE по символах пакета).
* **TX-обгортка**: потік DMA = заголовок `{OFTX, nbytes}` + payload (хвіст останнього beat ігнорується); пакети з поганим заголовком відкидаються;
  мінімальний проміжок між кадрами `GAP_SAMPLES` (RX обробляє один пакет за раз).
* **Регістри** `0x7C440000` (обидва білди): `0x00` ID (`OFRX`/`OFTX`), `0x04` CTRL (bit0 soft reset, bit1 clear), `0x08` SNAP (запис = знімок
  16 статусних слів, читати bit0 = готово), `0x10..` конфіг, `0x80..` статус (карти у шапці `phy_rx_axis_top.v` / `phy_tx_axis_top.v`).
  CDC: конфіг — 2-FF, знімок — handshake через toggle; false-path у XDC на `*u_regs/*_s1_reg*` та `stat_bank_reg`.
* **Прошивка**: `fw/build_frm.sh` (ROLE=rx|tx, WSL root) + `fw/dts/zynq-nano-sdr-pluto-ofdm-{rx,tx}.dts` (DMA-канали 64-біт stream, видалені вузли відсутнього PL).
* **Програма**: `sw/plutolink` (ролі tx / rx / diag / selftest), `analyze_logs.py`; опис, формат логів і вимірювань — `sw/plutolink/README.md`.
* Виправлено: `phy_tx_top.underflow` більше не спрацьовує в паузі між пакетами (прапор `tx_started_out` скидається по закінченню відтворення).
* Невідоме до першого запуску на залізі: частота `l_clk` (61.44 / 122.88 МГц), поведінка IIO DMA на межі пакета (tlast), формат даних АЦП,
  діапазони підсилення. Регресія симуляції: 66/66.

## Z7020 / PHY v2 (гілка OFDM_PHY_Z7020): прогрес
Порядок за ТЗ: Python reference -> RTL simulation -> Vivado synthesis (Z7020).
* **Код**: QC-LDPC, R = 5/6, N = 2160, K = 1800, Z = 60, база 6x36 (інформаційна частина вага 3 без 4-циклів, парність 802.11n-стилю -> кодування накопиченням).
  2 кодових слова на OFDM-символ (4320 біт + 80 заповнювачів = 4400 біт), 450 байт/символ, ≈50.5 Мбіт/с до накладних витрат.
  `python/ldpc_ref.py`: кодер, layered normalised min-sum (float), перевірка синдрому. Eb/N0 для FER 1 % (BPSK/AWGN) ≈ 3.5 дБ.
* **Референс приймача v2** `python/phy2_ref.py`: оцінка каналу по LTS, шум по guard-бінах, MMSE/ZF, max-log LLR (рівномірний або з вагою на субнесучу),
  деінтерлівінг, LDPC, метрики якості (SNR avg/min, bad subcarriers, pilot EVM). Перший системний результат (символьний рівень, `python/phy2_test.py`):
  AWGN: uncoded 16-QAM ZF PER 1 % приблизно з 24 дБ, LDPC з ≈ 16 дБ; 2 промені: uncoded PER 65 % ще на 26 дБ, LDPC 0 % з 18 дБ.
  MMSE vs ZF: з рівномірним LLR MMSE кращий (PER 35 % проти 60 % на 18 дБ), з LLR із вагою на субнесучу різниці майже немає.
* Далі: інтеграція в `phy_sim` (TX/RX backend v2, порівняння Current vs New), fine timing / residual CFO / SFO, fixed-point моделі, RTL, Vivado Z7020, report.
