#!/bin/bash
# TestTask004: full implementation of the RX project in three configurations (same RTL, parameters through the environment, see system_bd.tcl):
#   baseline (no patch logic), patch_a (uncertainty-aware LLR), patch_b (patch A + code-aided second pass).
# Reports of every build are copied to ../nano_sdr_pluto_ofdm/phy_sim/results/rxenh/impl_<name>/ .   usage: bash build_rxenh.sh [names...]
cd "$(dirname "$0")" || exit 1
V=/c/AMDDesignTools/2025.2/Vivado/bin
OUT=../nano_sdr_pluto_ofdm/phy_sim/results/rxenh
export ADI_IGNORE_VERSION_CHECK=1
for name in ${@:-baseline patch_a patch_b}; do
  case $name in
    baseline) export PHY_UA_HW=0 PHY_UA=0 PHY_CA=0 ;;
    patch_a)  export PHY_UA_HW=1 PHY_UA=1 PHY_CA=0 ;;
    patch_b)  export PHY_UA_HW=1 PHY_UA=1 PHY_CA=1 ;;
    *) echo "unknown configuration $name"; exit 1 ;;
  esac
  $V/vivado.bat -mode batch -log build.log -journal build.jou -source system_project.tcl > build_console_$name.txt 2>&1
  echo "BUILD_EXIT $name $? $(date +%H:%M)" >> build_chain.log
  $V/vivado.bat -mode batch -source post_reports.tcl -journal post.jou -log post.log > /dev/null 2>&1
  mkdir -p $OUT/impl_$name
  cp reports_*.rpt $OUT/impl_$name/
  cp nano_sdr_pluto_ofdm_rx.runs/*phy_rx*/*utilization_synth.rpt nano_sdr_pluto_ofdm_rx.runs/synth_1/*utilization_synth.rpt $OUT/impl_$name/ 2>/dev/null
  echo "REPORTS $name $(date +%H:%M)" >> build_chain.log
done
echo CHAIN_DONE >> build_chain.log
