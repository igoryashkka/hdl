#!/bin/sh
# Force AD9361 into LVDS mode at runtime to validate PlutoSky HDL.
# This bypasses the missing 'adi,lvds-mode-enable' DT property.
set -e
D=/sys/kernel/debug/iio/iio:device0/direct_reg_access
AXI=0x79020000

write_reg() {
  printf "0x%03X 0x%02X\n" "$1" "$2" > "$D"
}
read_reg() {
  printf "0x%X\n" "$1" > "$D"
  cat "$D"
}

echo "=== BEFORE: axi_ad9361 status ==="
echo "CLK_FREQ_0x54=$(devmem $((AXI+0x54)) 32)"
echo "CLK_RATIO_0x58=$(devmem $((AXI+0x58)) 32)"
echo "DRP_STATUS_0x74=$(devmem $((AXI+0x74)) 32)"
echo "reg 0x010 = $(read_reg 0x010)"
echo "reg 0x011 = $(read_reg 0x011)"
echo "reg 0x012 = $(read_reg 0x012)"
echo "reg 0x03C = $(read_reg 0x03C)"

echo "=== Switching chip to ALERT state (safe to reconfig PP) ==="
echo alert > /sys/bus/iio/devices/iio:device1/ensm_mode 2>/dev/null || \
  iio_attr -d ad9361-phy ensm_mode alert

sleep 1

echo "=== Writing LVDS Parallel Port config ==="
# Reg 0x010 = 0xC8 = TX_SWAP_IQ | RX_SWAP_IQ | RX_FRAME_PULSE_MODE  (keep as-is)
# Reg 0x011 = 0x00
# Reg 0x012: bit2=LVDS=1, bit3=SDR=0(DDR), bit1=HalfDup=0, bit0=SinglePort=0, bit4=SwapPorts=0
write_reg 0x012 0x04
# Reg 0x03C = LVDS Bias Control: 0xC0 enable | bias = 150mV/75 = 2
write_reg 0x03C 0xC2
# LVDS Invert Control regs (defaults from ADI reference)
write_reg 0x026 0x0F
write_reg 0x027 0x00

sleep 1

echo "=== AFTER reg writes ==="
echo "reg 0x012 = $(read_reg 0x012)"
echo "reg 0x03C = $(read_reg 0x03C)"
echo "reg 0x026 = $(read_reg 0x026)"
echo "reg 0x027 = $(read_reg 0x027)"

echo "=== Force calibration via sample rate re-set ==="
iio_attr -c -o ad9361-phy voltage0 sampling_frequency 5000000 || true
sleep 1
iio_attr -c -o ad9361-phy voltage0 sampling_frequency 30720000 || true
sleep 2

echo "=== Switch back to FDD ==="
iio_attr -d ad9361-phy ensm_mode fdd
sleep 1

echo "=== AFTER: axi_ad9361 status ==="
echo "CLK_FREQ_0x54=$(devmem $((AXI+0x54)) 32)"
echo "CLK_RATIO_0x58=$(devmem $((AXI+0x58)) 32)"
echo "DRP_STATUS_0x74=$(devmem $((AXI+0x74)) 32)"
echo "PN_ERR_0x404=$(devmem $((AXI+0x404)) 32)"
echo "PN_OOS_0x408=$(devmem $((AXI+0x408)) 32)"

echo "=== RX capture test (5s) ==="
rm -f /tmp/rx_lvds.iq /tmp/rx_lvds.err
iio_readdev -b 4096 -s 16384 cf-ad9361-lpc voltage0 voltage1 \
    > /tmp/rx_lvds.iq 2> /tmp/rx_lvds.err &
PID=$!
sleep 5
kill -9 $PID 2>/dev/null || true
wait 2>/dev/null || true

ls -lh /tmp/rx_lvds.iq
echo "--- stderr ---"
cat /tmp/rx_lvds.err
echo "--- first 64 bytes ---"
od -An -tx2 -N 64 /tmp/rx_lvds.iq
