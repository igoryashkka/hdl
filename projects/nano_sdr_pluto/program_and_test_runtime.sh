#!/bin/sh
set -u

firmware=${1:-/tmp/system_top.bit.bin}
firmware_name=system_top.bit.bin

if [ ! -f "$firmware" ]; then
	echo "missing firmware: $firmware" >&2
	exit 1
fi

md5sum "$firmware"
cp "$firmware" "/lib/firmware/$firmware_name"
chmod 0644 "/lib/firmware/$firmware_name"
md5sum "/lib/firmware/$firmware_name"

echo 0 > /sys/class/fpga_manager/fpga0/flags
echo "$firmware_name" > /sys/class/fpga_manager/fpga0/firmware
echo "FPGA_STATE=$(cat /sys/class/fpga_manager/fpga0/state)"

echo '--- rebind ad9361 spi'
if [ -e /sys/bus/spi/drivers/ad9361/spi0.0 ]; then
	echo spi0.0 > /sys/bus/spi/drivers/ad9361/unbind
fi
if ! echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind; then
	echo 'AD9361_BIND_FAILED=1'
fi

echo '--- bind dmac/cf_axi'
for dev in 7c400000.dma 7c420000.dma; do
	[ -e "/sys/bus/platform/drivers/dma-axi-dmac/$dev" ] && \
		echo "$dev" > /sys/bus/platform/drivers/dma-axi-dmac/unbind
	echo "$dev" > /sys/bus/platform/drivers/dma-axi-dmac/bind || true
done

for item in \
	'cf_axi_dds 79024000.cf-ad9361-dds-core-lpc' \
	'cf_axi_adc 79020000.cf-ad9361-lpc'; do
	set -- $item
	driver=$1
	device=$2
	[ -e "/sys/bus/platform/drivers/$driver/$device" ] && \
		echo "$device" > "/sys/bus/platform/drivers/$driver/unbind"
	echo "$device" > "/sys/bus/platform/drivers/$driver/bind" || true
done

echo '--- iio devices'
for name_file in /sys/bus/iio/devices/iio:device*/name; do
	[ -e "$name_file" ] || continue
	echo -n "$name_file="
	cat "$name_file"
done

echo '--- rx smoke'
rm -f /tmp/rx_nano.bin /tmp/rx_nano.err
iio_readdev -u local: -T 5000 -b 4096 -s 16384 cf-ad9361-lpc voltage0 > \
	/tmp/rx_nano.bin 2>/tmp/rx_nano.err
rx_status=$?
echo "RX_STATUS=$rx_status"
echo "RX_BYTES=$(wc -c < /tmp/rx_nano.bin 2>/dev/null || echo 0)"
echo "RX_ERR=$(cat /tmp/rx_nano.err 2>/dev/null)"
od -An -t d2 -N 128 /tmp/rx_nano.bin 2>/dev/null || true

echo '--- dmesg tail'
dmesg | grep -Ei 'ad936|cf_axi|dmac|dma|spi|deferred|product|failed|error' | tail -180