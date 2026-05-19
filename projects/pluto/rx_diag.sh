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

echo '--- filter_fir_en state'
for ch in voltage0 voltage1; do
  val="$(iio_attr -u local: -d cf-ad9361-lpc -c $ch filter_fir_en 2>/dev/null | awk '{print $NF}')"
  echo "  cf-ad9361-lpc $ch filter_fir_en = ${val:-<n/a>}"
done

echo '--- phy sampling frequency'
iio_attr -u local: -d ad9361-phy -c voltage0 sampling_frequency 2>/dev/null || echo "  <unreadable>"

echo '--- iio_readdev voltage0 (baseline)'
rm -f /tmp/rx.bin /tmp/rx.err
iio_readdev -u local: -T 5000 -b 1024 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx.bin 2>/tmp/rx.err
status=$?
echo "RX_STATUS=$status"
printf 'RX_BYTES='
wc -c < /tmp/rx.bin 2>/dev/null
cat /tmp/rx.err

BASE_BYTES="$(wc -c < /tmp/rx.bin 2>/dev/null)"
if [ "${BASE_BYTES:-0}" -gt 0 ] 2>/dev/null; then
  echo '[OK] data flowing — no fix needed'
  exit 0
fi

echo '--- fix A: force filter_fir_en=0 (bypass FIR decimator)'
iio_attr -u local: -d cf-ad9361-lpc -c voltage0 filter_fir_en 0 >/dev/null 2>&1
iio_attr -u local: -d cf-ad9361-lpc -c voltage1 filter_fir_en 0 >/dev/null 2>&1
echo "  voltage0 filter_fir_en now = $(iio_attr -u local: -d cf-ad9361-lpc -c voltage0 filter_fir_en 2>/dev/null | awk '{print $NF}')"

rm -f /tmp/rx_a.bin /tmp/rx_a.err
iio_readdev -u local: -T 3000 -b 256 -s 1024 cf-ad9361-lpc voltage0 > /tmp/rx_a.bin 2>/tmp/rx_a.err
A_BYTES="$(wc -c < /tmp/rx_a.bin 2>/dev/null)"
echo "RX_BYTES after fix A = $A_BYTES"
cat /tmp/rx_a.err
if [ "${A_BYTES:-0}" -gt 0 ] 2>/dev/null; then
  echo '[OK] fix A worked: FIR decimator was stalled, bypass restored flow'
  echo '     next: check HLS FIR IP (ap_ctrl free-run, rate mismatch, TREADY)'
  exit 0
fi
echo '[--] fix A had no effect'

echo '--- fix B: re-trigger phy->fabric handshake (rewrite sampling_frequency)'
RX_RATE="$(iio_attr -u local: -d ad9361-phy -c voltage0 sampling_frequency 2>/dev/null | awk '{print $NF}')"
if [ -n "$RX_RATE" ] && [ "$RX_RATE" -gt 0 ] 2>/dev/null; then
  echo "  rewriting sampling_frequency=$RX_RATE"
  iio_attr -u local: -d ad9361-phy -c voltage0 sampling_frequency "$RX_RATE" >/dev/null 2>&1
  sleep 1
  rm -f /tmp/rx_b.bin /tmp/rx_b.err
  iio_readdev -u local: -T 3000 -b 256 -s 1024 cf-ad9361-lpc voltage0 > /tmp/rx_b.bin 2>/tmp/rx_b.err
  B_BYTES="$(wc -c < /tmp/rx_b.bin 2>/dev/null)"
  echo "RX_BYTES after fix B = $B_BYTES"
  cat /tmp/rx_b.err
  if [ "${B_BYTES:-0}" -gt 0 ] 2>/dev/null; then
    echo '[OK] fix B worked: cf_axi_adc<->phy handshake was lost after rebind'
    exit 0
  fi
  echo '[--] fix B had no effect'
else
  echo '  skipping fix B: phy rate unknown'
fi

echo '--- ADC DMA registers (0x7c400000)'
for off in 0x000 0x004 0x020 0x024 0x028 0x02c 0x030 0x034 0x400 0x404 0x408 0x40c 0x410; do
  addr="$(printf '0x%08x' $(( 0x7c400000 + off )) 2>/dev/null)"
  val="$(devmem "$addr" 32 2>/dev/null || echo ERR)"
  printf '  [%s] = %s\n' "$addr" "$val"
done

echo '[FAIL] both fixes failed — likely a bitstream-level issue'
echo '       candidates: ilvector_logic/ilconstant synthesis bug, BUFR clock region mismatch,'
echo '       or HLS FIR TREADY/TVALID deadlock'
