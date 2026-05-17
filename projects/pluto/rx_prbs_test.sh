#!/bin/sh
set -u

echo '--- enable prbs'
echo 1 > /sys/kernel/debug/iio/iio:device0/bist_prbs
cat /sys/kernel/debug/iio/iio:device0/bist_prbs

echo '--- pn check'
cat /sys/kernel/debug/iio/iio:device3/pseudorandom_err_check

echo '--- read prbs samples'
rm -f /tmp/rx_prbs.bin /tmp/rx_prbs.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx_prbs.bin 2>/tmp/rx_prbs.err
status=$?
bytes=$(wc -c < /tmp/rx_prbs.bin 2>/dev/null || echo 0)
echo "status=$status bytes=$bytes err=$(cat /tmp/rx_prbs.err)"
od -An -t d2 -N 128 /tmp/rx_prbs.bin

echo '--- pn check after read'
cat /sys/kernel/debug/iio/iio:device3/pseudorandom_err_check

echo '--- disable prbs'
echo 0 > /sys/kernel/debug/iio/iio:device0/bist_prbs
cat /sys/kernel/debug/iio/iio:device0/bist_prbs
