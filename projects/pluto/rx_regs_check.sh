#!/bin/sh

echo ---ADC_COMMON_REGS---
for a in \
  0x79020000 0x79020004 0x79020008 0x7902000c \
  0x79020040 0x79020044 0x79020048 0x7902004c \
  0x79020050 0x79020054 0x79020058 0x7902005c; do
  printf "%s " "$a"
  devmem "$a" 32 2>/dev/null || echo ERR
done

echo ---ADC_CHANNEL_REGS---
for base in 0x79020400 0x79020440 0x79020480 0x790204c0; do
  echo CHANNEL_BASE=$base
  for off in 0x00 0x04 0x08 0x0c 0x10 0x14 0x18 0x1c 0x20 0x24 0x28 0x2c 0x30; do
    a=$(printf "0x%08x" $((base + off)))
    printf "%s " "$a"
    devmem "$a" 32 2>/dev/null || echo ERR
  done
done

echo ---DMAC_REGS_BEFORE---
for a in 0x7c400000 0x7c400004 0x7c400008 0x7c40000c 0x7c400010 0x7c400014 0x7c400400 0x7c400404 0x7c400408 0x7c40040c 0x7c400410 0x7c400414 0x7c400418 0x7c40041c; do
  printf "%s " "$a"
  devmem "$a" 32 2>/dev/null || echo ERR
done

echo ---RX_ALL_FOR_REG_CHECK---
iio_readdev -u local: -T 5000 -b 1024 -s 1024 cf-ad9361-lpc > /tmp/rx_regs_all.bin 2>/tmp/rx_regs_all.err
echo st=$?
echo bytes=$(wc -c < /tmp/rx_regs_all.bin)
echo err=$(cat /tmp/rx_regs_all.err)
od -An -t x2 -N 128 /tmp/rx_regs_all.bin

echo ---DMAC_REGS_AFTER---
for a in 0x7c400000 0x7c400004 0x7c400008 0x7c40000c 0x7c400010 0x7c400014 0x7c400400 0x7c400404 0x7c400408 0x7c40040c 0x7c400410 0x7c400414 0x7c400418 0x7c40041c; do
  printf "%s " "$a"
  devmem "$a" 32 2>/dev/null || echo ERR
done

echo ---INTERRUPTS_DMAC---
grep -E "7c400000|cf-ad9361" /proc/interrupts || true