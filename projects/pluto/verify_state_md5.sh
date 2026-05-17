#!/bin/sh
set -u

echo "FPGA_STATE=$(cat /sys/class/fpga_manager/fpga0/state)"
ls -l /lib/firmware/system_top.bit.bin
md5sum /lib/firmware/system_top.bit.bin 2>/dev/null || true
for addr in 0x79020000 0x79020054 0x7902005c 0x79020400 0x79020404 0x79020408; do
  printf '%s=' "$addr"
  devmem "$addr" 32 2>&1 || true
done
