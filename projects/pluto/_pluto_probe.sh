echo '---MODEL---'
tr -d '\000' </proc/device-tree/model; echo

echo '---IIO DEVICES---'
for d in /sys/bus/iio/devices/iio:device*; do
  [ -f "$d/name" ] && echo "$(basename "$d"): $(cat "$d/name")"
done

echo '---AD9361 DT NODES---'
for f in $(find /sys/firmware/devicetree/base -type f -name compatible 2>/dev/null); do
  v=$(tr -d '\000' < "$f" 2>/dev/null || true)
  echo "$v" | grep -qi 'ad9361' || continue
  d=$(dirname "$f")
  echo "NODE=$d"
  echo "compatible=$v"
  for p in \
    adi,lvds-mode-enable \
    adi,2rx-2tx-mode-enable \
    adi,full-port-enable \
    adi,single-port-mode-enable \
    adi,swap-ports-enable \
    adi,pp-rx-swap-enable \
    adi,pp-tx-swap-enable \
    adi,fdd-rx-rate-2tx-enable \
    adi,rx-data-delay \
    adi,tx-fb-clock-delay \
    adi,rx-data-clock-delay \
    adi,tx-data-delay; do
    if [ -f "$d/$p" ]; then
      val=$(od -An -tu4 -N4 "$d/$p" 2>/dev/null | tr -s ' ' | sed 's/^ //')
      [ -z "$val" ] && val=$(tr -d '\000' < "$d/$p" 2>/dev/null || true)
      echo "$p=$val"
    fi
  done
  echo

done

echo '---AD9361 IIO KEY ATTRS---'
PHY=$(grep -l '^ad9361-phy$' /sys/bus/iio/devices/iio:device*/name | sed 's#/name##' | head -n1)
if [ -n "$PHY" ]; then
  for a in ensm_mode in_voltage_sampling_frequency out_voltage_sampling_frequency in_voltage_rf_bandwidth out_voltage_rf_bandwidth in_voltage0_rf_port_select in_voltage1_rf_port_select; do
    [ -f "$PHY/$a" ] && echo "$a=$(cat "$PHY/$a")"
  done
fi

echo '---CF-ADC ATTRS---'
ADC=$(grep -l '^cf-ad9361-lpc$' /sys/bus/iio/devices/iio:device*/name | sed 's#/name##' | head -n1)
if [ -n "$ADC" ]; then
  for a in in_voltage_sampling_frequency in_voltage_sampling_frequency_available in_voltage_samples_pps sync_start_enable sync_start_enable_available; do
    if [ -f "$ADC/$a" ]; then
      printf '%s=' "$a"
      cat "$ADC/$a"
    fi
  done
fi