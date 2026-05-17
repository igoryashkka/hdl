#!/bin/sh
set -u

echo '--- ad9361 dt nodes'
find /proc/device-tree -iname '*ad936*' -o -iname '*936*' 2>/dev/null

node=''
for path in \
  /proc/device-tree/amba/spi@e0006000/ad9361-phy@0 \
  /proc/device-tree/amba/spi@e0006000/ad9361@0 \
  /proc/device-tree/*/*ad936* \
  /proc/device-tree/*/*/*ad936*; do
  if [ -d "$path" ]; then
    node="$path"
    break
  fi
done

echo "NODE=$node"
[ -n "$node" ] || exit 1

echo '--- compatible'
[ -f "$node/compatible" ] && tr '\0' '\n' < "$node/compatible"

echo '--- adi boolean props'
for prop in "$node"/adi,*; do
  [ -e "$prop" ] || continue
  name="$(basename "$prop")"
  size="$(wc -c < "$prop" 2>/dev/null || echo 0)"
  if [ "$size" = 0 ]; then
    echo "$name=<bool>"
  else
    printf '%s=' "$name"
    od -An -tx1 "$prop" | tr -d ' \n'
    echo
  fi
done
