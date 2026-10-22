# nano_sdr_pluto_ofdm_tx7020 — OFDM PHY TX на платі Pluto з Zynq-7020 (LVDS)

Передавач dual-mode OFDM PHY (`../nano_sdr_pluto_ofdm/rtl`, v0.8.0) для плати з проєкту `projects/pluto`
гілки `docs/pluto-runtime-bitstream-jtag` (коміт d206de1f9): xc7z020clg400-2, AD9363 через LVDS.

## Що змінено відносно `projects/pluto`

| | `projects/pluto` | цей проєкт |
|---|---|---|
| TX-тракт | DAC DMA (циклічний) → upack → інтерполятор → DAC | DAC DMA (не циклічний, 64-біт stream) → `phy_tx` → DAC канал 0 |
| Регістри PHY | — | `0x7C440000` (`phy_regs_axil`, ID `OFTX`) |
| RX-тракт | decimator → cpack → ADC DMA | без змін (щоб працював штатний device tree) |
| ILA | `rx_debug_ila` | прибрано |
| Тактовий констрейнт `rx_clk` | 4 нс | 8 нс: PHY працює лише на 30.72 МС/с (`l_clk` ≤ 122.88 МГц) |

Адреси `axi_ad9361` (`0x79020000`) і DMA (`0x7C400000`, `0x7C420000`) ті самі, що у штатному дизайні, тому після
заливки бітстріму через JTAG штатний Linux і його драйвери працюють далі.

## Збірка

```
build_vivado.bat                      (Vivado 2025.2, ≈ 1 год)
vivado -mode batch -source post_reports.tcl     (звіти таймінгу й ресурсів)
```
Бітстрім: `nano_sdr_pluto_ofdm_tx7020.runs/impl_1/system_top.bit` (стиснений).

## Запуск на платі (метод з `README_runtime_bitstream.md`: JTAG, до перезавантаження)

1. Плата завантажена зі штатною прошивкою, `ssh root@192.168.2.1` працює, JTAG-адаптер під'єднано.
2. Залити бітстрім:
   ```
   C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat program_pl_jtag.tcl
   ```
   Скрипт лише заливає PL. Що в PL саме цей бітстрім, перевіряє крок 5 (`plutolink diag` показує `PHY ID OFTX`).
3. Перезавантажити драйвери AD9361:
   ```
   ssh root@192.168.2.1 "modprobe -r cf_axi_dds cf_axi_adc ad9361_drv ad9361 2>/dev/null; sleep 1; modprobe ad9361; sleep 2; ls /sys/bus/iio/devices/"
   ```
4. Скопіювати програму (статичний ARM-бінарник, `../nano_sdr_pluto_ofdm/sw/plutolink/plutolink`):
   ```
   scp ../nano_sdr_pluto_ofdm/sw/plutolink/plutolink root@192.168.2.1:/tmp/
   ```
5. Перевірка:
   ```
   ssh root@192.168.2.1 /tmp/plutolink diag
   ```
   Очікується `PHY ID OFTX`, частота `l_clk` і темп відліків ЦАП близько 30.72 МС/с. Якщо `UNKNOWN`, у PL не той бітстрім;
   якщо знімок регістрів не встигає, немає `l_clk` (драйвер AD9361 не налаштував інтерфейс).
6. Передача (спершу кабель і 30–60 дБ атенюації, див. `sw/plutolink/README.md`):
   ```
   /tmp/plutolink tx --freq 2450e6 --nsyms 2 --mode 0 --gain -60 --rate 200 --log run1
   ```
   `--mode 0` = MAX RANGE (QPSK, LDPC 1/2), `--mode 1` = MAX RATE (16-QAM, LDPC 5/6). Кожну секунду друкуються лічильники PHY
   (прийняті / відтворені пакети, переповнення, темп ЦАП), наприкінці кількість пакетів і швидкість payload.

## Як перевірити передавач без другого PHY

Друга плата зі штатною прошивкою, налаштована на 30.72 МС/с і ту саму частоту, записує IQ першого каналу
(`iio_readdev -b 1048576 -s 30720000 cf-ad9361-lpc voltage0 voltage1 > cap.iq`, int16 I/Q). Запис розкодовує
Python-приймач фреймворку `phy_sim`:
```
cd ../nano_sdr_pluto_ofdm/phy_sim
python -m phy_sim.cli replay path/to/cap.iq --out results/hw_cap1
```
Поруч із `cap.iq` покладіть `metadata.json` з параметрами передавача, інакше приймач візьме типові:
```
{"config": {"payload": {"nsyms": 2}, "phy": {"mode": "max_range"}}}
```
Що це покаже: чи кадри виявляються, як сходиться LDPC, EVM, CFO. Чого не покаже: BER проти переданих даних, бо replay
порівнює з власною тестовою послідовністю, а не з PRBS програми `plutolink`. Так видно, чи передавач видає правильні
кадри, ще до порту приймача в PL. Приймач у PL для цієї
плати (`nano_sdr_pluto_ofdm_rx` під LVDS) ще не портовано.

## Не перевірено

Нічого з цього не запускалось на залізі. Зокрема: чи штатний драйвер `cf-ad9361-dds-core-lpc` без змін віддає буфер у
не циклічний DMA (на Nano SDR Pluto для цього був свій device tree), і чи плата працює в 1R1T чи 2R2T (PHY працює в обох,
використовується канал 0).
