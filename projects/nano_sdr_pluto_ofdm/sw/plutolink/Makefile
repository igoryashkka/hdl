# plutolink build
#   make host   : native build (selftest only needs this)       make arm : static ARM binary for the Pluto (needs arm-linux-gnueabihf-gcc)
CFLAGS ?= -O2 -Wall -Wextra -std=gnu11
all: host arm

host: plutolink_host
plutolink_host: plutolink.c
	$(CC) $(CFLAGS) -o $@ $< -lm

arm: plutolink
plutolink: plutolink.c
	arm-linux-gnueabihf-gcc $(CFLAGS) -static -o $@ $< -lm

test: plutolink_host
	./plutolink_host selftest

clean:
	rm -f plutolink plutolink_host
.PHONY: all host arm test clean
