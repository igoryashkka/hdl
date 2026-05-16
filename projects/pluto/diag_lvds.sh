#!/bin/sh
echo "=== all dmesg related ==="
dmesg | grep -iE 'pluto|ad936|cf_axi|lvds|cmos|axi-ad' | head -40
echo
echo "=== pp/swap props in live DT ==="
for f in /proc/device-tree/amba/spi@e0006000/ad9361-phy@0/adi,pp*; do
  printf "%s = " "$(basename $f)"
  xxd "$f" 2>/dev/null | head -1
done
echo
echo "=== sampling/ensm/calib ==="
iio_attr -c ad9361-phy voltage0 sampling_frequency
iio_attr -d ad9361-phy ensm_mode
iio_attr -d ad9361-phy calib_mode 2>/dev/null
echo
echo "=== all ad9361-phy DT props ==="
ls /proc/device-tree/amba/spi@e0006000/ad9361-phy@0/ | head -60
echo
echo "=== chip regs full PP block ==="
D=/sys/kernel/debug/iio/iio:device0/direct_reg_access
for r in 0x010 0x011 0x012 0x013 0x015 0x016 0x017 0x026 0x027 0x03A 0x03B 0x03C 0x03D; do
  echo $r > $D
  printf "reg %s = %s\n" $r "$(cat $D)"
done
