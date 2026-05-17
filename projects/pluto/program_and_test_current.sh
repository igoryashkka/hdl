#!/bin/sh
set -u

echo 0 > /sys/class/fpga_manager/fpga0/flags
echo system_top.bit.bin > /sys/class/fpga_manager/fpga0/firmware
echo "FPGA_STATE=$(cat /sys/class/fpga_manager/fpga0/state)"
md5sum /lib/firmware/system_top.bit.bin 2>/dev/null || true

sh /tmp/rebind_rx.sh

echo "--- iio devices"
for name_file in /sys/bus/iio/devices/iio:device*/name; do
	[ -e "$name_file" ] || continue
	echo -n "$name_file="
	cat "$name_file"
done

echo "--- rx raw sample test"
rm -f /tmp/rx.bin /tmp/rx.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx.bin 2>/tmp/rx.err
rx_status=$?
echo "RX_STATUS=$rx_status"
echo "RX_BYTES=$(wc -c < /tmp/rx.bin 2>/dev/null || echo 0)"
echo "RX_ERR=$(cat /tmp/rx.err 2>/dev/null)"
od -An -t d2 -N 128 /tmp/rx.bin 2>/dev/null || true

echo "--- adc mmio status"
devmem 0x79020054 32 2>/dev/null || true
devmem 0x79020058 32 2>/dev/null || true
devmem 0x7902005c 32 2>/dev/null || true
devmem 0x79020400 32 2>/dev/null || true
devmem 0x79020404 32 2>/dev/null || true
devmem 0x79020408 32 2>/dev/null || true
