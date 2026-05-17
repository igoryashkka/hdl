#!/bin/sh
set -u

D=/sys/kernel/debug/iio/iio:device0/direct_reg_access
rd() { printf '0x%03X\n' "$1" > "$D"; cat "$D"; }
wr() { printf '0x%03X 0x%02X\n' "$1" "$2" > "$D"; }

echo '--- current key regs'
for reg in 0x010 0x012 0x013 0x03c 0x026 0x027; do printf '%s=' "$reg"; rd "$reg"; done

echo '--- read all enabled by iio_readdev no channel list'
rm -f /tmp/rx_all.bin /tmp/rx_all.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc > /tmp/rx_all.bin 2>/tmp/rx_all.err
status=$?
bytes=$(wc -c < /tmp/rx_all.bin 2>/dev/null || echo 0)
echo "ALL_STATUS=$status ALL_BYTES=$bytes ALL_ERR=$(cat /tmp/rx_all.err)"
od -An -t d2 -N 256 /tmp/rx_all.bin

echo '--- enable bist tone'
echo 1 > /sys/kernel/debug/iio/iio:device0/bist_tone 2>/dev/null || true
cat /sys/kernel/debug/iio/iio:device0/bist_tone 2>&1 || true
rm -f /tmp/rx_tone.bin /tmp/rx_tone.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc > /tmp/rx_tone.bin 2>/tmp/rx_tone.err
status=$?
bytes=$(wc -c < /tmp/rx_tone.bin 2>/dev/null || echo 0)
echo "TONE_STATUS=$status TONE_BYTES=$bytes TONE_ERR=$(cat /tmp/rx_tone.err)"
od -An -t d2 -N 256 /tmp/rx_tone.bin

echo '--- disable bist tone'
echo 0 > /sys/kernel/debug/iio/iio:device0/bist_tone 2>/dev/null || true
cat /sys/kernel/debug/iio/iio:device0/bist_tone 2>&1 || true
