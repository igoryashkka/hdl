# nano_sdr_pluto_gfsk_demod — RX-only, PL GFSK demodulator (WIP)

Гілка: `GFSK_FPGA_Demod`. Базовий проєкт: `../nano_sdr_pluto` (commit 999d881bd).

## Стан (2026-10-03)

| Пункт | Статус |
|---|---|
| TX-тракт прибрано з BD (`tx_fir_interpolator`, `tx_upack`, `logic_or`, `interp_slice`, `axi_ad9361_dac_dma`, його HP2/IRQ/адреса) | зроблено в тексті, **не зібрано** |
| TX-порти прибрано з `system_top.v` і XDC (14 рядків) | зроблено |
| `PROJECT_NAME` / `adi_project_create` перейменовано | зроблено |
| Tcl-файли синтаксично цілі (`info complete`) | перевірено |
| Синтез Vivado | **не запускався** |
| IQ-трейс (`axi_ad9361_adc_dma` → HP1 → USB) | **ще є**, замінюється на PL-демод |
| PL-демодулятор (канали, FM-дискримінатор, сінк, PN9/CRC) | **не написано** |

## Цільова схема RX (ще не реалізована)

```
AD9361 RX (ADC 12-bit) ─► rx_fir_decimator (поточний, 4.5 MS/s)
   │
   ▼
[ch_bank]   N = 15 каналів (EU_Hop з ABF_FREQ_LIST_KHZ), per channel:
            NCO (зсув у DC) → CIC ÷8 → FIR 31 → IQ @ 562.5 kS/s
   │
   ├─► [burst_det] per channel: |x|² → noise floor (асиметричне відстеження) → поріг → IDLE/ACTIVE
   │       події: канал, t_start, t_end (лічильник 64 біти)
   ▼
[gfsk_demod] тільки під час ACTIVE: FM-дискримінатор (atan2 або CORDIC) → LPF
   → тактова синхронізація (дробовий такт 234.375 смп/біт при 4.5 MS/s; після ÷8 ≈ 29.3)
   → рішення біта
   ▼
[frame] сінк 0x91D3 (з толерантністю 1 біт), PN9 дешифрування, довжина, CRC8, CRC16
   ▼
AXI-stream → DMA → PS: тільки декодовані кадри (байти + канал + час + статус CRC)
```

Точний референс для порівняння — Python `hopping_detector/` і C `hopping_detector/c/` (`hopdet`):
на `capture_300MB.iq` мають збігатися номери пакетів, лічильники, канали і байти кадру.

## Що ще треба вирішити до написання RTL

1. **Фіксована точка**: ширина FIR-коефіцієнтів і акумуляторів, розрядність FM-дискримінатора. Золотий тест: побітово відповідає float-версії `hopdet` на 59 дійсних тривогах.
2. **Режим 1R1T чи 2R2T**: у BD стоїть `MODE_1R1T 0` (2R2T), а Pluto Rev.C працює в `mode=1r1t`. Перевірити перед збіркою.
3. **Ресурси Z7010**: 80 DSP48E1, ~2 Мбіт BRAM. Оцінка банку з 15 каналів з CIC і коротким FIR — вкладається, але підтвердити синтезом.
4. **Тактові домени**: AD9361 `l_clk` ~ 61.44 МГц (після `rx_fir_decimator`), сист. CPU — окремо; перехід через AXI-stream FIFO.

## Linux

Гілка `GFSK_FPGA_Demod` у `/home/user/linux` містить незакомічені зміни DTS і defconfig (`zynq-nano-sdr-pluto.dts`, `zynq_nano_sdr_pluto_defconfig`) з попередньої роботи. Після зміни PL треба перегенерувати DTS з нового xsa (без XSCT), видалити вузли TX DMA/DDS з `zynq-pluto-sdr.dtsi`, і додати вузол для AXI-stream/DMA кадрів.
