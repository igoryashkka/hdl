#!/bin/sh
set -u

echo '--- iio devices'
for d in /sys/bus/iio/devices/iio:device*; do
  [ -e "$d/name" ] && echo "$d: $(cat "$d/name")"
done

echo '--- kernel rx lines'
dmesg | grep -Ei 'ad936|cf_axi|dmac|dma|tuning|calib|timeout|failed|error' | tail -120

echo '--- ad9361 attrs'
for f in \
  /sys/bus/iio/devices/iio:device0/name \
  /sys/bus/iio/devices/iio:device0/in_voltage_rf_bandwidth \
  /sys/bus/iio/devices/iio:device0/in_voltage_sampling_frequency \
  /sys/bus/iio/devices/iio:device0/out_altvoltage0_RX_LO_frequency \
  /sys/bus/iio/devices/iio:device0/in_voltage0_gain_control_mode \
  /sys/bus/iio/devices/iio:device0/in_voltage0_hardwaregain; do
  [ -e "$f" ] && { printf '%s=' "$f"; cat "$f"; }
done

echo '--- cf-ad9361-lpc buffer'
find /sys/bus/iio/devices/iio:device3/buffer -maxdepth 1 -type f -print -exec cat {} \;

echo '--- cf-ad9361-lpc scan_elements'
find /sys/bus/iio/devices/iio:device3/scan_elements -maxdepth 1 -type f -print -exec cat {} \;

echo '--- cf-ad9361-lpc regs'
for a in 0x0000 0x0004 0x0008 0x000c 0x0010 0x0014 0x0018 0x001c 0x0040 0x0044 0x0048 0x004c 0x0080 0x0084 0x0088 0x008c; do
  printf '%s ' "$a"
  iio_reg -u local: cf-ad9361-lpc "$a" 2>&1
done

echo '--- iio_readdev voltage0'
rm -f /tmp/rx.bin /tmp/rx.err
iio_readdev -u local: -T 5000 -b 1024 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx.bin 2>/tmp/rx.err
status=$?
echo "RX_STATUS=$status"
printf 'RX_BYTES='
wc -c < /tmp/rx.bin 2>/dev/null
cat /tmp/rx.err
