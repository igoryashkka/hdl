#!/bin/sh
set -u

D=/sys/kernel/debug/iio/iio:device0/direct_reg_access

rd() {
  printf '0x%03X\n' "$1" > "$D"
  cat "$D"
}

wr() {
  printf '0x%03X 0x%02X\n' "$1" "$2" > "$D"
}

hex_to_dec() {
  value="$1"
  value="${value#0x}"
  printf '%d' "0x$value"
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

phy="$(find_iio_by_name ad9361-phy || true)"

echo "PHY=$phy"
echo '--- before regs'
for reg in 0x010 0x011 0x012 0x013 0x03c 0x026 0x027; do
  printf '%s=' "$reg"
  rd "$reg"
done

if [ -n "$phy" ] && [ -e "$phy/ensm_mode" ]; then
  echo '--- ensm alert'
  echo alert > "$phy/ensm_mode" 2>/dev/null || true
  cat "$phy/ensm_mode" 2>/dev/null || true
fi

old012="$(rd 0x012)"
old012_dec="$(hex_to_dec "$old012")"
new012=$((old012_dec | 0x04))

echo "--- write LVDS bit preserving swap: 0x012 $old012 -> $(printf '0x%02X' "$new012")"
wr 0x012 "$new012"
wr 0x03c 0xc2

if [ -n "$phy" ] && [ -e "$phy/ensm_mode" ]; then
  echo '--- ensm fdd'
  echo fdd > "$phy/ensm_mode" 2>/dev/null || true
  cat "$phy/ensm_mode" 2>/dev/null || true
fi

if [ -e /sys/kernel/debug/iio/iio:device0/digital_tune ]; then
  echo '--- digital tune'
  echo 1 > /sys/kernel/debug/iio/iio:device0/digital_tune 2>/dev/null || true
  cat /sys/kernel/debug/iio/iio:device0/digital_tune 2>/dev/null || true
fi

echo '--- after regs'
for reg in 0x010 0x011 0x012 0x013 0x03c 0x026 0x027; do
  printf '%s=' "$reg"
  rd "$reg"
done

echo '--- mmio status before prbs'
for addr in 0x79020054 0x79020058 0x7902005c 0x79020400 0x79020404 0x79020408; do
  printf '%s=' "$addr"
  devmem "$addr" 32 2>&1 || true
done

echo '--- prbs test'
echo 1 > /sys/kernel/debug/iio/iio:device0/bist_prbs 2>/dev/null || true
cat /sys/kernel/debug/iio/iio:device0/bist_prbs 2>&1 || true
cat /sys/kernel/debug/iio/iio:device3/pseudorandom_err_check 2>&1 || true
rm -f /tmp/rx_prbs2.bin /tmp/rx_prbs2.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx_prbs2.bin 2>/tmp/rx_prbs2.err
status=$?
bytes=$(wc -c < /tmp/rx_prbs2.bin 2>/dev/null || echo 0)
echo "PRBS_RX_STATUS=$status PRBS_RX_BYTES=$bytes PRBS_RX_ERR=$(cat /tmp/rx_prbs2.err)"
od -An -t d2 -N 128 /tmp/rx_prbs2.bin
cat /sys/kernel/debug/iio/iio:device3/pseudorandom_err_check 2>&1 || true
echo 0 > /sys/kernel/debug/iio/iio:device0/bist_prbs 2>/dev/null || true

echo '--- normal rx test'
rm -f /tmp/rx_lvds_fixed.bin /tmp/rx_lvds_fixed.err
iio_readdev -u local: -T 5000 -b 4096 -s 4096 cf-ad9361-lpc voltage0 > /tmp/rx_lvds_fixed.bin 2>/tmp/rx_lvds_fixed.err
status=$?
bytes=$(wc -c < /tmp/rx_lvds_fixed.bin 2>/dev/null || echo 0)
echo "RX_STATUS=$status RX_BYTES=$bytes RX_ERR=$(cat /tmp/rx_lvds_fixed.err)"
od -An -t d2 -N 128 /tmp/rx_lvds_fixed.bin
