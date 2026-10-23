#!/bin/sh
# Autonomous start of a beamforming board without a PC (TestTask006 7.4, NOT YET VERIFIED ON HARDWARE).
# Instead of rebuilding the board firmware (pluto.frm for the Zynq-7020 LVDS board is not available), Linux loads the PL at
# boot through the kernel FPGA manager, the built-in AD9361 drivers are re-probed (same sequence as bringup.ps1) and beamd starts.
#
# Install (once, files on the persistent flash of the board, path to be checked on the board: /mnt/jffs2 on Pluto firmware):
#   scp -O system_top.bit.bin beamd bf_autostart.sh root@<board>:/mnt/jffs2/bf/
#   and call   /mnt/jffs2/bf/bf_autostart.sh <role> &   from the board's start-up hook.
# role: leader | follower | single | anchor (anchor: no PL load, stock bitstream)   extra beamd options after the role.
# Log: /tmp/bf_autostart.log, beamd logs /tmp/beamd_*.csv.
# Requirements to verify on the board: /sys/class/fpga_manager/fpga0 exists, /lib/firmware is writable (tmpfs) or the firmware
# search path contains the .bin, the .bin is the byte-swapped bitstream (bootgen -process_bitstream bin, see make_bin.bat).
DIR=$(dirname "$0")
ROLE=${1:-leader}; shift
exec > /tmp/bf_autostart.log 2>&1
echo "bf_autostart $ROLE $(date)"
if [ "$ROLE" != "anchor" ]; then
  FM=/sys/class/fpga_manager/fpga0
  [ -d $FM ] || { echo "no FPGA manager in this kernel: load the bitstream over JTAG (bringup.ps1)"; exit 1; }
  mkdir -p /lib/firmware && cp "$DIR/system_top.bit.bin" /lib/firmware/ || exit 1
  echo 0 > $FM/flags
  echo system_top.bit.bin > $FM/firmware || { echo "PL load failed"; exit 1; }
  echo "PL: $(cat $FM/state)"
  unbind() { [ -e "/sys/bus/$1/drivers/$2/$3" ] && echo "$3" > "/sys/bus/$1/drivers/$2/unbind"; }
  bind()   { [ -e "/sys/bus/$1/drivers/$2/$3" ] || echo "$3" > "/sys/bus/$1/drivers/$2/bind"; }
  unbind platform cf_axi_adc 79020000.cf-ad9361-lpc
  unbind platform cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
  unbind platform dma-axi-dmac 7c400000.dma
  unbind platform dma-axi-dmac 7c420000.dma
  unbind spi ad9361 spi0.0
  sleep 1
  bind spi ad9361 spi0.0
  sleep 2
  bind platform dma-axi-dmac 7c400000.dma
  bind platform dma-axi-dmac 7c420000.dma
  bind platform cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
  bind platform cf_axi_adc 79020000.cf-ad9361-lpc
  sleep 1
fi
P=$(grep -l "^ad9361-phy$" /sys/bus/iio/devices/iio:device*/name | xargs dirname)
echo 30720000 > $P/in_voltage_sampling_frequency
echo "sampling frequency $(cat $P/in_voltage_sampling_frequency)"
exec "$DIR/beamd" "$ROLE" --log /tmp/beamd "$@"
