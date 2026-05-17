#!/bin/sh
set -u

dev=/sys/kernel/debug/iio/iio:device0
adc=/sys/kernel/debug/iio/iio:device3

for f in bist_tone bist_prbs bist_timing_analysis loopback gaininfo_rx1 gaininfo_rx2 digital_tune direct_reg_access; do
  echo "===$f==="
  cat "$dev/$f" 2>&1 | head -80 || true
done

echo '===adc_pseudorandom_err_check==='
cat "$adc/pseudorandom_err_check" 2>&1 || true

echo '===adc_direct_reg_access==='
cat "$adc/direct_reg_access" 2>&1 || true
