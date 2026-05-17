#!/bin/sh

echo ---IIO_DEVICES---
iio_info -u local: -s 2>/dev/null || true

echo ---CF_AD9361_LPC_SCAN---
d=""
for x in /sys/bus/iio/devices/iio:device*; do
  n=$(cat "$x/name" 2>/dev/null)
  echo "$x $n"
  if [ "$n" = "cf-ad9361-lpc" ]; then
    d=$x
  fi
done

if [ -n "$d" ]; then
  ls -1 "$d/scan_elements"
  for f in "$d"/scan_elements/*; do
    printf "%s=" "$(basename "$f")"
    cat "$f"
  done
fi

echo ---RX_VOLTAGE0---
iio_readdev -u local: -T 5000 -b 1024 -s 1024 cf-ad9361-lpc voltage0 > /tmp/rx_v0.bin 2>/tmp/rx_v0.err
echo st=$?
echo bytes=$(wc -c < /tmp/rx_v0.bin)
echo err=$(cat /tmp/rx_v0.err)
od -An -t d2 -N 128 /tmp/rx_v0.bin

echo ---RX_VOLTAGE1---
iio_readdev -u local: -T 5000 -b 1024 -s 1024 cf-ad9361-lpc voltage1 > /tmp/rx_v1.bin 2>/tmp/rx_v1.err
echo st=$?
echo bytes=$(wc -c < /tmp/rx_v1.bin)
echo err=$(cat /tmp/rx_v1.err)
od -An -t d2 -N 128 /tmp/rx_v1.bin

echo ---RX_ALL_DEVICE---
iio_readdev -u local: -T 5000 -b 1024 -s 1024 cf-ad9361-lpc > /tmp/rx_all.bin 2>/tmp/rx_all.err
echo st=$?
echo bytes=$(wc -c < /tmp/rx_all.bin)
echo err=$(cat /tmp/rx_all.err)
od -An -t x2 -N 256 /tmp/rx_all.bin

echo ---NONZERO_ALL_LINES---
od -An -t d2 /tmp/rx_all.bin | grep -v "^[[:space:]0]*$" | head -20