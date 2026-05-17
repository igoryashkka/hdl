#!/bin/sh
set -u

unbind_if_bound() {
  driver="$1"
  device="$2"
  path="/sys/bus/platform/drivers/$driver/$device"
  if [ -e "$path" ]; then
    echo "unbind platform $driver $device"
    echo "$device" > "/sys/bus/platform/drivers/$driver/unbind"
  fi
}

bind_platform() {
  driver="$1"
  device="$2"
  echo "bind platform $driver $device"
  echo "$device" > "/sys/bus/platform/drivers/$driver/bind"
}

find_iio_by_name() {
  target="$1"
  for name_file in /sys/bus/iio/devices/iio:device*/name; do
    [ -e "$name_file" ] || continue
    if [ "$(cat "$name_file")" = "$target" ]; then
      dirname "$name_file"
      return 0
    fi
  done
  return 1
}

echo '--- before iio'
for name_file in /sys/bus/iio/devices/iio:device*/name; do [ -e "$name_file" ] && echo "$name_file=$(cat "$name_file")"; done

unbind_if_bound cf_axi_adc 79020000.cf-ad9361-lpc
unbind_if_bound cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
unbind_if_bound dma-axi-dmac 7c400000.dma
unbind_if_bound dma-axi-dmac 7c420000.dma

if [ -e /sys/bus/spi/drivers/ad9361/spi0.0 ]; then
  echo 'unbind spi ad9361 spi0.0'
  echo spi0.0 > /sys/bus/spi/drivers/ad9361/unbind
elif [ -e /sys/bus/spi/drivers/ad9361-phy/spi0.0 ]; then
  echo 'unbind spi ad9361-phy spi0.0'
  echo spi0.0 > /sys/bus/spi/drivers/ad9361-phy/unbind
fi

sleep 1

if [ -d /sys/bus/spi/drivers/ad9361 ]; then
  echo 'bind spi ad9361 spi0.0'
  echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind
elif [ -d /sys/bus/spi/drivers/ad9361-phy ]; then
  echo 'bind spi ad9361-phy spi0.0'
  echo spi0.0 > /sys/bus/spi/drivers/ad9361-phy/bind
else
  echo 'ERROR: no ad9361 spi driver found'
fi

sleep 3

bind_platform dma-axi-dmac 7c400000.dma
bind_platform dma-axi-dmac 7c420000.dma
bind_platform cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
bind_platform cf_axi_adc 79020000.cf-ad9361-lpc

sleep 1

echo '--- after iio'
for name_file in /sys/bus/iio/devices/iio:device*/name; do [ -e "$name_file" ] && echo "$name_file=$(cat "$name_file")"; done

echo '--- mmio status'
for addr in 0x79020000 0x79020040 0x79020054 0x79020058 0x7902005c 0x79020400 0x79020404 0x79020408; do
  printf '%s=' "$addr"
  devmem "$addr" 32 2>&1 || true
done

echo '--- prbs test'
echo 1 > /sys/kernel/debug/iio/iio:device0/bist_prbs 2>/dev/null || true
cat /sys/kernel/debug/iio/iio:device3/pseudorandom_err_check 2>&1 || true
echo 0 > /sys/kernel/debug/iio/iio:device0/bist_prbs 2>/dev/null || true

echo '--- rx read'
rm -f /tmp/rx_full.bin /tmp/rx_full.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx_full.bin 2>/tmp/rx_full.err
status=$?
bytes=$(wc -c < /tmp/rx_full.bin 2>/dev/null || echo 0)
echo "RX_STATUS=$status RX_BYTES=$bytes RX_ERR=$(cat /tmp/rx_full.err)"
od -An -t d2 -N 128 /tmp/rx_full.bin
