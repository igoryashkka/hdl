#!/bin/bash
# Regenerate golden vectors and run every block TB. Exit non-zero on any failure.
cd "$(dirname "$0")/.." || exit 1
python python/generate_vectors.py > /dev/null || exit 1
fail=0
run() { # name [generic]
  if GENERIC="$2" sim/run_tb.sh "$1" > /tmp/tb_$1.log 2>&1; then echo "PASS $1 $2"; else echo "FAIL $1 $2"; cat /tmp/tb_$1.log; fail=1; fi
}
run tb_phy_scrambler
run tb_phy_crc
for o in 4 16 64; do run tb_phy_qam_mapper ORDER=$o; run tb_phy_qam_demapper ORDER=$o; done
for c in "1 4 15" "2 6 63" "4 4 0" "3 11 255" "5 11 2047"; do set -- $c; run tb_phy_fft_core "TAG=$1 N_LOG=$2 MASK=$3"; done
for c in "1 0 4 1 55 20" "2 1 4 1 55 20" "3 0 32 8 55 20" "4 1 32 8 55 20" "5 0 4 1 5 4" "6 1 4 1 5 4"; do set -- $c; run tb_phy_interleaver "TAG=$1 DEINT=$2 WORD_W=$3 ROT_UNIT=$4 ROWS=$5 COLS=$6"; done
run tb_phy_ofdm_mapper
run tb_phy_pilot_insert
run tb_phy_preamble_gen
for c in "1 4 15" "2 4 0" "3 11 255"; do set -- $c; run tb_phy_ifft_2048 "TAG=$1 N_LOG=$2 MASK=$3"; done
for c in "1 16384" "2 8192" "3 65535" "4 0" "5 24000"; do set -- $c; run tb_phy_tx_scaler "TAG=$1 GAIN=$2"; done
for c in "1 4 4" "2 11 144" "3 5 0"; do set -- $c; run tb_phy_cp_insert "TAG=$1 N_LOG=$2 CP=$3"; done
run tb_phy_tx_top CODED=0
run tb_phy_tx_top "CODED=1 MODE=1"
run tb_phy_tx_top "CODED=1 MODE=0"
run tb_phy_ldpc_enc MODE=1
run tb_phy_ldpc_enc MODE=0
run tb_phy_hdr
for t in 1 2 3; do run tb_phy_sync_sc "TAG=$t"; done
for c in "1 10" "2 4"; do set -- $c; run tb_phy_dc_remove "TAG=$1 K=$2"; done
for c in "1 0" "2 3" "3 -3" "4 7" "5 -8"; do set -- $c; run tb_phy_input_scale "TAG=$1 SH=$2"; done
for c in "1 0" "2 268435456" "3 -123456789" "4 19088743" "5 -2147483648"; do set -- $c; run tb_phy_nco_mixer "TAG=$1 INC=$2"; done
run tb_phy_cordic
run tb_phy_cfo_coarse
run tb_phy_rx_window "N=16 SYM=21 NWIN=3"
run tb_phy_rx_window "N=2048 SYM=2192 NWIN=3"
for c in "1 4 15" "2 4 0" "3 11 15"; do set -- $c; run tb_phy_rx_fft "TAG=$1 N_LOG=$2 MASK=$3"; done
run tb_phy_bin_select
run tb_phy_channel_estimator SM=0
run tb_phy_channel_estimator SM=1
run tb_phy_equalizer
run tb_phy_phase_tracker SLOPE=0
run tb_phy_phase_tracker SLOPE=1
run tb_phy_rx_decode
run tb_phy_rx_pkt_out V3=0
run tb_phy_rx_pkt_out V3=1
run tb_phy_rx_top CODED=0
run tb_phy_rx_top "CODED=1 MODE=1"
run tb_phy_rx_top "CODED=1 MODE=0"
run tb_phy_rx_top "CODED=1 MODE=2"
run tb_phy_ldpc_dec MODE=1
run tb_phy_ldpc_dec MODE=0
run tb_phy_ldpc_dec "MODE=1 POST=1"
run tb_phy_ldpc_dec "MODE=0 POST=1"
run tb_phy_llr_demap QP=0
run tb_phy_llr_demap QP=1
run tb_phy_llr_demap "QP=0 UA=1"
run tb_phy_noise_est
run tb_phy_mmse_post
run tb_phy_rx_decode_ldpc MODE=1
run tb_phy_rx_decode_ldpc MODE=0
run tb_phy_regs_axil
run tb_phy_rx_axis_top
run tb_phy_tx_axis_top
# code-aided second pass (TestTask004 Patch B): phy_rx_top (UA + CA) in xsim against the fixed-point back-end model on the RTL's own tracker output
if (cd phy_sim && python experiments/rtl_runs_rxenh.py --check) > /tmp/tb_rxenh.log 2>&1; then echo "PASS rxenh_rtl_check UA=1 CA=1"; else echo "FAIL rxenh_rtl_check"; cat /tmp/tb_rxenh.log; fail=1; fi
exit $fail
