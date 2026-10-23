# beamd build
#   make host : native build (selftest / estimate on files)     make arm : static ARM binary for the Pluto boards
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11
all: host arm

host: beamd_host
beamd_host: beamd.c fbmodem.h
	$(CC) $(CFLAGS) -pthread -o $@ $< -lm

arm: beamd
beamd: beamd.c fbmodem.h
	arm-linux-gnueabihf-gcc $(CFLAGS) -mfpu=neon -mfloat-abi=hard -static -pthread -o $@ $< -lm

test: beamd_host
	./beamd_host selftest

clean:
	rm -f beamd beamd_host
.PHONY: all host arm test clean
