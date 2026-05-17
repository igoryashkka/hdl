#!/bin/sh
set -u

unbind_if_bound() {
  driver="$1"
  device="$2"
  path="/sys/bus/platform/drivers/$driver/$device"
  if [ -e "$path" ]; then
    echo "unbind $driver $device"
    echo "$device" > "/sys/bus/platform/drivers/$driver/unbind"
  else
    echo "skip unbind $driver $device"
  fi
}

bind_device() {
  driver="$1"
  device="$2"
  echo "bind $driver $device"
  echo "$device" > "/sys/bus/platform/drivers/$driver/bind"
}

echo '--- before'
ls /sys/bus/iio/devices/iio:device*/name 2>/dev/null | xargs -r -n1 sh -c 'echo -n "$0="; cat "$0"'

unbind_if_bound cf_axi_adc 79020000.cf-ad9361-lpc
unbind_if_bound cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
unbind_if_bound dma-axi-dmac 7c400000.dma
unbind_if_bound dma-axi-dmac 7c420000.dma

bind_device dma-axi-dmac 7c400000.dma
bind_device dma-axi-dmac 7c420000.dma
bind_device cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
bind_device cf_axi_adc 79020000.cf-ad9361-lpc

echo '--- after'
ls /sys/bus/iio/devices/iio:device*/name 2>/dev/null | xargs -r -n1 sh -c 'echo -n "$0="; cat "$0"'

echo '--- read test'
rm -f /tmp/rx.bin /tmp/rx.err
iio_readdev -u local: -T 5000 -b 1024 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx.bin 2>/tmp/rx.err
status=$?
echo "RX_STATUS=$status"
printf 'RX_BYTES='
wc -c < /tmp/rx.bin 2>/dev/null
cat /tmp/rx.err

echo '--- dmesg tail'
dmesg | grep -Ei 'ad936|cf_axi|dmac|dma|tuning|calib|timeout|failed|error' | tail -120
