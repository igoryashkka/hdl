# nano_sdr_pluto_ofdm — Long-Range Video PHY (OFDM, 16-QAM, LDPC)

Гілка `OFDM_PHY`. ТЗ: `../nano_sdr_pluto/TestTask.md`, правила розробки: `../nano_sdr_pluto/CLAUDE.md`.
## Структура: спільне ядро + два білди
```
nano_sdr_pluto_ofdm/      спільне: rtl/ tb/ python/ sim/ (цей каталог, не Vivado-проєкт)
nano_sdr_pluto_ofdm_tx/   TX-only білд: PS -> DMA(mem->stream) -> PHY TX -> AD9361 DAC     (0x7C420000, irq 12)
nano_sdr_pluto_ofdm_rx/   RX-only білд: AD9361 ADC -> PHY RX -> DMA(stream->mem) -> PS    (0x7C400000, irq 13)
```
Весь фізичний рівень у PL; у PS іде лише потік пакетів через DMA (64-біт AXI-stream), пакетайзер — програма на C.
Жодного IQ по USB. Обидва білди згенеровані з `../nano_sdr_pluto` викиданням зайвого (FIR, ILA, cpack, ADC/DAC DMA, TX/RX піни де можливо).
У TX-only лишаються RX-піни (rx_clk_in/frame/data): `l_clk` ядра axi_ad9361 береться з DATA_CLK мікросхеми.
`rtl/rx/phy_rx_axis_top.v` і `rtl/tx/phy_tx_axis_top.v` — **заглушки** (RX: heartbeat-пакет, TX: IQ passthrough),
замінюються реальним ланцюжком блок за блоком.
Збірка: `nano_sdr_pluto_ofdm_{rx,tx}/build_vivado.bat` (Vivado 2025.2, ~5 хв).
Стан (з заглушками PHY): обидва білди проходять синтез+імплементацію+бітстрім+xsa.
RX-only: WNS +0.787 / TNS 0 / WHS +0.025 / THS 0. TX-only: WNS +0.894 / TNS 0 / WHS +0.016 / THS 0.
Критичні попередження DRC про DDR (DIFF_SSTL) — штатні для PS7, як у базовому проєкті. На залізі ще не перевірено.

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
| RX: front-end (scale/DC/IQ/power/AGC), sync (packet det, CFO, NCO, timing), cp_remove, FFT-обгортка, channel est., equalizer, phase tracker, RX top | ❌ | | | |
| System TB + channel model (AWGN/CFO/multipath/Doppler) | ❌ | | | |

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
Статус RX RTL: ще не написано (див. таблицю вище).
