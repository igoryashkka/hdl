#!/bin/sh
set -u

D=/sys/kernel/debug/iio/iio:device0/direct_reg_access
rd() { printf '0x%03X\n' "$1" > "$D"; cat "$D"; }
wr() { printf '0x%03X 0x%02X\n' "$1" "$2" > "$D"; }

rebind_basic() {
  for pair in \
    'cf_axi_adc 79020000.cf-ad9361-lpc' \
    'cf_axi_dds 79024000.cf-ad9361-dds-core-lpc' \
    'dma-axi-dmac 7c400000.dma' \
    'dma-axi-dmac 7c420000.dma'; do
    set -- $pair
    [ -e "/sys/bus/platform/drivers/$1/$2" ] && echo "$2" > "/sys/bus/platform/drivers/$1/unbind"
  done
  for pair in \
    'dma-axi-dmac 7c400000.dma' \
    'dma-axi-dmac 7c420000.dma' \
    'cf_axi_dds 79024000.cf-ad9361-dds-core-lpc' \
    'cf_axi_adc 79020000.cf-ad9361-lpc'; do
    set -- $pair
    echo "$2" > "/sys/bus/platform/drivers/$1/bind" 2>/dev/null || true
  done
}

set_lvds() {
  old="$(rd 0x012)"
  old_hex="${old#0x}"
  new=$((0x$old_hex | 0x04))
  wr 0x012 "$new"
  wr 0x03c 0xc2
  printf 'reg012=%s reg03c=%s\n' "$(rd 0x012)" "$(rd 0x03c)"
}

capture_one() {
  tag="$1"
  rm -f "/tmp/rx_${tag}.bin" "/tmp/rx_${tag}.err"
  iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc > "/tmp/rx_${tag}.bin" 2>"/tmp/rx_${tag}.err"
  status=$?
  bytes=$(wc -c < "/tmp/rx_${tag}.bin" 2>/dev/null || echo 0)
  echo "${tag}_STATUS=$status ${tag}_BYTES=$bytes ${tag}_ERR=$(cat "/tmp/rx_${tag}.err")"
  od -An -t d2 -N 128 "/tmp/rx_${tag}.bin"
}

run_one() {
  file="$1"
  tag="$2"
  echo "=== $tag program $file ==="
  ls -l "/lib/firmware/$file" || return 1
  echo 0 > /sys/class/fpga_manager/fpga0/flags
  echo "$file" > /sys/class/fpga_manager/fpga0/firmware
  cat /sys/class/fpga_manager/fpga0/state
  rebind_basic
  set_lvds
  echo 'mmio:'
  for addr in 0x79020000 0x79020054 0x7902005c 0x79020400 0x79020404 0x79020408; do printf '%s=' "$addr"; devmem "$addr" 32; done
  capture_one "$tag"
}

ls -l /lib/firmware/*system_top*.bin 2>/dev/null || true
run_one vendor_system_top.bit.bin vendor
run_one system_top.bit.bin current
