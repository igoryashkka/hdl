#!/bin/bash
# Builds pluto.frm for one Nano SDR Pluto OFDM PHY board (ROLE=rx|tx). Run in WSL as root: wsl -u root ...
#   ROLE=rx|tx ./build_frm.sh [path/to/system_top.xsa]      (default xsa: ../../nano_sdr_pluto_ofdm_<role>/nano_sdr_pluto_ofdm_<role>.sdk/system_top.xsa)
# Inputs : the XSA from Vivado (zip, only the .bit inside is used), the stock pluto.frm v0.38
#          (rootfs is taken from it unchanged), the Linux tree (branch GFSK_FPGA_Demod).
# Output : $OUT/pluto.frm   (copy it to the PlutoSDR mass-storage drive, Eject, wait for the reboot)
# FSBL and U-Boot stay the vendor ones: no Vitis needed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROLE=${ROLE:?set ROLE=rx or ROLE=tx}
XSA=${1:-$HERE/../../nano_sdr_pluto_ofdm_${ROLE}/nano_sdr_pluto_ofdm_${ROLE}.sdk/system_top.xsa}
STOCK=${STOCK:-/mnt/c/Users/user/Documents/sdr_hdl/jtag_boot/adi_v038/pluto.frm}
LINUX=${LINUX:-/home/user/linux}
KOUT=${KOUT:-/root/kbuild}
OUT=${OUT:-/root/fw_ofdm_${ROLE}}
DTB_NAME=zynq-nano-sdr-pluto-ofdm-${ROLE}

export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
mkdir -p "$OUT" && cd "$OUT"

echo "== 1/5 bitstream from $XSA"
rm -rf xsa && mkdir xsa && python3 -m zipfile -e "$XSA" xsa
BIT=$(ls xsa/*.bit | head -n1)
cp "$BIT" system_top.bit
ls -l system_top.bit

echo "== 2/5 rootfs from the stock image"
head -c -33 "$STOCK" > ref.itb                       # drop the md5 line (32 hex + newline)
dumpimage -T flat_dt -p 5 -o rootfs.cpio.gz ref.itb >/dev/null
test -s rootfs.cpio.gz && gzip -t rootfs.cpio.gz && ls -l rootfs.cpio.gz

echo "== 3/5 kernel and dtb ($LINUX, dts/${DTB_NAME}.dts)"
make -C "$LINUX" O="$KOUT" zynq_nano_sdr_pluto_defconfig >/dev/null
make -C "$LINUX" O="$KOUT" -j"$(nproc)" zImage UIMAGE_LOADADDR=0x8000 2>&1 | tail -3
# the role DTS lives in this repo (fw/dts); it includes zynq-pluto-sdr.dtsi from the Linux tree -> cpp + dtc, no tree changes
cpp -nostdinc -undef -x assembler-with-cpp -I "$LINUX/arch/arm/boot/dts" -I "$LINUX/include" -I "$LINUX/scripts/dtc/include-prefixes"     -o dts.pp "$HERE/dts/${DTB_NAME}.dts"
dtc -I dts -O dtb -i "$LINUX/arch/arm/boot/dts" -o pluto.dtb dts.pp
cp "$KOUT/arch/arm/boot/zImage" zImage
ls -l zImage pluto.dtb

echo "== 4/5 FIT (same structure as the stock image)"
{
cat <<EOF
/dts-v1/;
/ {
    description = "Configuration to load fpga before Kernel";
    magic = "ITB PlutoSDR (ADALM-PLUTO)";
    #address-cells = <1>;
    images {
EOF
for i in 1 2 3; do cat <<EOF
        fdt@$i {
            description = "$DTB_NAME";
            data = /incbin/("pluto.dtb");
            type = "flat_dt";
            arch = "arm";
            compression = "none";
        };
EOF
done
cat <<EOF
        fpga@1 {
            description = "FPGA";
            data = /incbin/("system_top.bit");
            type = "fpga";
            arch = "arm";
            compression = "none";
            load = <0xf000000>;
            hash@1 { algo = "md5"; };
        };
        linux_kernel@1 {
            description = "Linux";
            data = /incbin/("zImage");
            type = "kernel";
            arch = "arm";
            os = "linux";
            compression = "none";
            load = <0x8000>;
            entry = <0x8000>;
            hash@1 { algo = "md5"; };
        };
        ramdisk@1 {
            description = "Ramdisk";
            data = /incbin/("rootfs.cpio.gz");
            type = "ramdisk";
            arch = "arm";
            os = "linux";
            compression = "gzip";
            hash@1 { algo = "md5"; };
        };
    };
    configurations {
        default = "config@0";
EOF
for c in 0 1 2 3 4 5 6 7 8 9 10; do
  fdt=$([ "$c" = 0 ] && echo 1 || { [ "$c" = 8 ] && echo 3 || echo 2; })
  cat <<EOF
        config@$c {
            description = "Linux with fpga";
            fdt = "fdt@$fdt";
            kernel = "linux_kernel@1";
            ramdisk = "ramdisk@1";
            fpga = "fpga@1";
        };
EOF
done
cat <<EOF
    };
};
EOF
} > pluto.its

echo "== 5/5 pack"
mkimage -f pluto.its pluto.itb >/dev/null
md5sum pluto.itb | cut -d' ' -f1 > pluto.itb.md5
cat pluto.itb pluto.itb.md5 > pluto.frm
ls -l pluto.frm
md5sum pluto.itb | cut -d' ' -f1
echo "OK: $OUT/pluto.frm  (stock was $(stat -c %s "$STOCK") bytes)"
