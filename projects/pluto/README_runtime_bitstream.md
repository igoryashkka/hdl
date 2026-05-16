# Runtime-завантаження власного бітстріму в PlutoSDR через JTAG

Цей документ описує **тимчасовий** (до reboot) спосіб залити власний
`system_top.bit` у PL Pluto без чіпання SD-картки та QSPI-флеша.
Використовується для швидкої валідації того, що **саме наш** бітстрім
працює на залізі.

---

## TL;DR

```powershell
# 1. Перебілдити .bit з TIMESTAMP-fingerprint
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch `
    -source C:\Users\user\Documents\sdr_hdl\jtag_boot\rebuild_bit_compressed.tcl

# 2. Залити через JTAG (xsdb)
& "C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat" `
    C:\Users\user\Documents\sdr_hdl\jtag_boot\program_pl.tcl

# 3. RX (швидше за все) ляже — перезавантажити AD9361 driver на Pluto:
ssh root@192.168.2.1 "modprobe -r ad9361 ad9361_drv; modprobe ad9361"
```

Після `reboot` Pluto знову завантажить **ADI-шний** бітстрім із SD —
наш зникне. Це і є основне обмеження методу.

---

## Чому саме такий шлях

### 1. Спроба перепрошити QSPI — провалилась

* `mtd0` на Pluto має лише **1 МБ**.
* Наш `BOOT.bin` (fsbl + bitstream + u-boot) **2.76 МБ** — не вліз навіть зі стисненням.
* ADI вкладається у 1 МБ тому, що використовує власний u-boot SPL + специфічні
  обрізки. Перепакувати самостійно без офіційного `plutosdr-fw` flow ризиковано.

### 2. Спроба підмінити `BOOT.bin` на SD-картці — провалилась

* SD-розділ має `boot_size=0xF00000` (15 МБ) — місця досить.
* Підмінили `BOOT.bin` на `bootgen`-зібраний (наш fsbl.elf + наш .bit + наш u-boot.elf).
* **Pluto завис на boot**: ні UART-логу, ні USB-пристрою, ні мережі.
* Причина: `fsbl.elf` / `u-boot.elf`, які лежали в `jtag_boot/`, не були валідними
  ELF (magic ≠ `7F 45 4C 46`) — це fragments/stubs, не повноцінні бінарі.
  ADI Pluto чекає на свій fork U-Boot з patches для AD9361/USB-gadget.
* Відновлення: дістати SD, скопіювати `BOOT.bin.bak` назад → `BOOT.bin`.

### 3. Runtime-завантаження через JTAG — працює

* JTAG-pod на Pluto: FTDI **VID 0403 PID 6010** (USB Serial Converter A/B).
* `xsdb` бачить Cortex-A9 і може писати в PCAP напряму через
  `fpga -file <bit>` — це **гарячий перезалив PL** без рестарту PS/Linux.
* Linux **продовжує** працювати, але всі IP-блоки в PL отримують свіжий reset,
  тому драйвери (AD9361, DMA, IIO) втрачають синхронізацію зі стейтом — і
  їх треба перевантажити.

---

## Передумови

| Що                         | Де                                                                  |
|----------------------------|---------------------------------------------------------------------|
| Vivado / xsdb              | `C:\AMDDesignTools\2025.2\Vivado\bin\`                              |
| Зібраний проект Pluto      | `C:\Users\user\Documents\sdr_hdl\hdl\projects\pluto\pluto.xpr`      |
| JTAG-pod підключений       | Перевір: `Get-PnpDevice -PresentOnly  Where InstanceId match 0403`  |
| Pluto в нормальному режимі | `ssh root@192.168.2.1 uname -a` працює                              |

В `system_constr.xdc` вже додано (це створює унікальний fingerprint):

```tcl
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS  TRUE      [current_design]
```

---

## Крок 1. Перебілдити лише `.bit` (без impl run)

Tcl-скрипт [`rebuild_bit_compressed.tcl`](rebuild_bit_compressed.tcl):

```tcl
open_project C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.xpr
open_run impl_1
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]
write_bitstream -force C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.bit
puts "=== DONE ==="
close_project
exit
```

Запуск:

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch `
    -source C:\Users\user\Documents\sdr_hdl\jtag_boot\rebuild_bit_compressed.tcl
```

USR_ACCESS = momentний timestamp (приклад: `0x8AB4059E`,
що відповідає `Sun May 17 00:22:30 2026`) — це є криптографічний fingerprint
що відрізнить ваш .bit від ADI-шного.

---

## Крок 2. Залити в PL через JTAG (xsdb)

Створіть `program_pl.tcl`:

```tcl
connect
targets -set -filter {name =~ "*Cortex-A9*#0"}
fpga -file C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.bit
# Прочитати USR_ACCESS через DEVCFG_MCTRL (0xF8007080)
puts "USR_ACCESS = [format 0x%08X [mrd -value 0xF8007080]]"
disconnect
exit
```

Запуск:

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat" `
    C:\Users\user\Documents\sdr_hdl\jtag_boot\program_pl.tcl
```

Очікуваний вивід:
```
USR_ACCESS = 0x8AB4059E
```

— це **і є** ваш timestamp. Якщо співпадає з тим, що Vivado показав під час
write_bitstream — це 100% ваш бітстрім на залізі.

---

## Крок 3. Перевантажити драйвери AD9361 на Pluto

Після `fpga -file` Linux продовжує жити, але AD9361-driver "не бачить"
свіжо-зрезетений PL-блок. Симптом: `iio_readdev` зависає / повертає 0 байт.

```powershell
ssh root@192.168.2.1 @'
modprobe -r cf_axi_dds cf_axi_adc ad9361_drv ad9361 2>/dev/null
sleep 1
modprobe ad9361
sleep 2
ls /sys/bus/iio/devices/ | head
'@
```

Якщо modprobe не допомагає — RX може взагалі не оживати без full reboot
(зустрічалось в нашій сесії). Це **відома слабкість методу**: PL reset
розсинхронізує SPI/clock chain AD9361 і не завжди rescue-able без cold boot.

Перевірка RX:
```powershell
ssh root@192.168.2.1 "iio_readdev -b 16384 -s 65536 cf-ad9361-lpc 2>/dev/null | wc -c"
# очікуємо: 524288 (= 65536 sample * 8 bytes I+Q×2)
```

---

## Як перевірити, що це ВАШ бітстрім

Три способи від найслабшого до найсильнішого:

1. **AXI register check** — прочитати ваш кастомний регістр (якщо такий є):
   ```powershell
   ssh root@192.168.2.1 "devmem 0x79020000 32"  # axi_ad9361 VERSION
   ```

2. **USR_ACCESS через DEVCFG_MCTRL** — це **runtime read-out** значення,
   яке Vivado зашив у бітстрім:
   ```powershell
   ssh root@192.168.2.1 "devmem 0xF8007080 32"
   # очікуємо точно той самий 0x8AB4059E
   ```

3. **xsdb mrd 0xF8007080** — те саме, але через JTAG, без довіри Linux:
   ```tcl
   xsdb> mrd 0xF8007080
   ```

USR_ACCESS неможливо підробити з Linux (read-only register, заповнюється
PCAP'ом при завантаженні бітстріму) — найнадійніший доказ.

---

## Як відкотитись (back to ADI)

Просто:

```powershell
ssh root@192.168.2.1 "/sbin/reboot"
```

Pluto завантажиться з SD → отримає ADI bitstream → `USR_ACCESS` стане
ADI-шним. SD-картку чіпати не треба.

---

## Відомі підводні камені

| Проблема                                            | Рішення                                                                                                                           |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| SSH каже host key changed після reboot              | `ssh-keygen -R 192.168.2.1` + reinstall ключа з паролем `analog` (rootfs у Pluto = tmpfs, ключі не зберігаються)                  |
| `iio_readdev` зависає / 0 байт після JTAG-reload    | `modprobe -r ad9361; modprobe ad9361`. Якщо ні — `reboot` (втрачаємо наш .bit, але повертаємо робочий стан)                       |
| `device_reboot sf` не входить у DFU                 | Зустрічалось двічі — Pluto повертався в normal mode. Не покладатись.                                                              |
| `serial_io.ps1 -Cmd ""` падає                       | Передавати `-Cmd " "` (пробіл) для listen-only                                                                                    |
| `scp` каже `sftp-server: not found`                 | Pluto не має sftp. Використовувати `cmd /c "type file  ssh root@... cat > /dest"` для binary-safe upload                          |
| BOOT.bin після підміни → Pluto мертвий              | **Не змінюйте BOOT.bin** на SD без офіційного `plutosdr-fw` build flow. Дістайте SD, відновіть з .bak                             |

---

## Чому це варто

* Цикл «змінив RTL → побачив на залізі» < 1 хв (`write_bitstream` ~30 с,
  `fpga -file` < 10 с).
* Не псує SD/QSPI, не вимагає DFU, не вимагає `plutosdr-fw` repo.
* Дає **криптографічний доказ** (USR_ACCESS) того, що на залізі саме
  ваш бітстрім — а не якийсь кеш чи ADI fallback.
* Перезавантаження Pluto = повне відновлення до factory state.

Для **постійного** заміщення бітстріму без втрати після reboot —
треба офіційний `plutosdr-fw` flow з ADI fork U-Boot
(`https://github.com/analogdevicesinc/plutosdr-fw`), збираючи весь
BOOT.bin через їхній Makefile із підміною лише `system_top.bit`. Це окрема
задача, не покрита цим документом.
