#!/bin/sh
# Full AD9361 CMOS->LVDS register sequence
# Bypasses driver that reads DT 'adi,lvds-mode-enable' but doesn't write LVDS_MODE bit
set -e
D=/sys/kernel/debug/iio/iio:device0/direct_reg_access
AXI=0x79020000

rd() { printf "0x%X\n" "$1" > "$D"; cat "$D"; }
wr() { printf "0x%03X 0x%02X\n" "$1" "$2" > "$D"; }

echo "=== BEFORE ==="
printf "reg 0x012 = %s   reg 0x03C = %s   CLK_FREQ = %s\n" \
  "$(rd 0x012)" "$(rd 0x03C)" "$(devmem $((AXI+0x54)) 32)"

echo "=== Put ENSM into ALERT (safe state) ==="
# Reg 0x014 ENSM Config 1: 0x00 = alert from any state via force
wr 0x014 0x00
sleep 1

echo "=== Write full LVDS PP config ==="
# Reg 0x010 keep 0xC8 (IQ swaps & RX frame pulse mode)
# Reg 0x012 = 0x04: LVDS=1, SwapPorts=0 (clear bit4), SDR=0, FullDup, DualPort
wr 0x012 0x04
# Reg 0x013 = 0x00 (no bypass)
wr 0x013 0x00
# Reg 0x03C LVDS Bias: bit7 ENABLE, lower bits = 150mV/75=2 → 0x82, but datasheet says 0xC0|bias
wr 0x03C 0xC2
# Reg 0x017 Cal Clock Divider bit7 = LVDS clk divider enable for some variants
wr 0x017 0xE0
# LVDS invert defaults
wr 0x026 0x00
wr 0x027 0x00
# Some boards need REG 0x004 (CTRL OUT) - leave alone

echo "=== Force ENSM into FDD ==="
# Reg 0x015 - keep RX clk delay = 4
# Reg 0x014 ENSM Config 1: bit5 FORCE_ALERT_STATE=0, bit4 FORCE_RX_ON, bit3 FORCE_TX_ON, etc.
# For FDD: bit0 FORCE_ENABLE_PIN=0, FDD mode set by reg 0x013 bit0=1 or pp_conf
# Best to use ENSM via direct sysfs path:
echo "=== Re-arming via direct register ==="
wr 0x014 0x21   # ENSM enable, dual synth enable for FDD-style
sleep 2

echo "=== AFTER ==="
printf "reg 0x012 = %s   reg 0x03C = %s   reg 0x017 = %s\n" \
  "$(rd 0x012)" "$(rd 0x03C)" "$(rd 0x017)"
printf "CLK_FREQ = %s   CLK_RATIO = %s   DRP_STATUS = %s\n" \
  "$(devmem $((AXI+0x54)) 32)" "$(devmem $((AXI+0x58)) 32)" "$(devmem $((AXI+0x74)) 32)"

echo "=== RX capture test (5s) ==="
rm -f /tmp/rx.iq /tmp/rx.err
iio_readdev -b 4096 -s 8192 cf-ad9361-lpc voltage0 > /tmp/rx.iq 2>/tmp/rx.err &
P=$!
sleep 5
kill -9 $P 2>/dev/null || true
wait 2>/dev/null || true
ls -lh /tmp/rx.iq
cat /tmp/rx.err
od -An -tx2 -N 64 /tmp/rx.iq
