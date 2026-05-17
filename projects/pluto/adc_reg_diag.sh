#!/bin/sh
set -u

adc=/sys/kernel/debug/iio/iio:device3/direct_reg_access
phy=/sys/kernel/debug/iio/iio:device0/direct_reg_access

echo '--- adc direct regs'
for addr in 0x0000 0x0001 0x0002 0x0003 0x0004 0x0007 0x0010 0x0011 0x0013 0x0015 0x0016 0x0017 0x001a 0x0028 0x002e 0x002f 0x0030 0x0031 0x0040 0x0400 0x0404 0x0410 0x0414; do
  echo "$addr" > "$adc" 2>/tmp/adc_reg.err || true
  printf '%s=' "$addr"
  cat "$adc" 2>&1
  err=$(cat /tmp/adc_reg.err 2>/dev/null || true)
  [ -n "$err" ] && echo "err=$err"
  : > /tmp/adc_reg.err
done

echo '--- samples pps'
cat /sys/bus/iio/devices/iio:device3/in_voltage_samples_pps 2>&1 || true

echo '--- phy selected regs'
for addr in 0x000 0x005 0x006 0x007 0x00a 0x00b 0x00c 0x00d 0x012 0x013 0x014 0x015 0x016 0x017 0x03f 0x058 0x059 0x05a 0x05b 0x05c 0x05d; do
  echo "$addr" > "$phy" 2>/tmp/phy_reg.err || true
  printf '%s=' "$addr"
  cat "$phy" 2>&1
  err=$(cat /tmp/phy_reg.err 2>/dev/null || true)
  [ -n "$err" ] && echo "err=$err"
  : > /tmp/phy_reg.err
done
