#!/bin/sh
set -u

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
rx="$(find_iio_by_name cf-ad9361-lpc || true)"

echo "PHY=$phy"
echo "RX=$rx"

echo '--- ad9361 attrs'
for attr in \
  out_altvoltage0_RX_LO_frequency \
  in_voltage_rf_bandwidth \
  in_voltage_sampling_frequency \
  in_voltage0_rf_port_select \
  in_voltage0_gain_control_mode \
  in_voltage0_hardwaregain \
  in_voltage0_rssi \
  in_voltage1_rf_port_select \
  in_voltage1_gain_control_mode \
  in_voltage1_hardwaregain \
  in_voltage1_rssi; do
  [ -n "$phy" ] && [ -e "$phy/$attr" ] && echo "$attr=$(cat "$phy/$attr")"
done

echo '--- scan elements'
if [ -n "$rx" ] && [ -d "$rx/scan_elements" ]; then
  for attr in "$rx"/scan_elements/*; do
    [ -f "$attr" ] && echo "$(basename "$attr")=$(cat "$attr")"
  done
fi

sample_channel() {
  channel="$1"
  out="/tmp/${channel}.bin"
  err="/tmp/${channel}.err"
  rm -f "$out" "$err"
  iio_readdev -u local: -T 5000 -b 4096 -s 32768 cf-ad9361-lpc "$channel" > "$out" 2>"$err"
  status=$?
  bytes=$(wc -c < "$out" 2>/dev/null || echo 0)
  echo "--- $channel"
  echo "status=$status bytes=$bytes err=$(cat "$err")"
  od -An -v -t d2 "$out" | awk '
    BEGIN { n=0; min=0; max=0; sumabs=0; sumsq=0; nonzero=0 }
    {
      for (i = 1; i <= NF; i++) {
        v = $i + 0
        if (n == 0 || v < min) min = v
        if (n == 0 || v > max) max = v
        av = v < 0 ? -v : v
        sumabs += av
        sumsq += v * v
        if (v != 0) nonzero++
        n++
      }
    }
    END {
      if (n > 0) {
        printf("samples=%d nonzero=%d min=%d max=%d mean_abs=%.2f rms=%.2f\n", n, nonzero, min, max, sumabs/n, sqrt(sumsq/n))
      } else {
        print "samples=0"
      }
    }'
  echo 'first64='
  od -An -t d2 -N 128 "$out"
}

sample_channel voltage0
sample_channel voltage1
