#!/bin/sh
# HLS FIR filter diagnostic script.
# Tests the custom FIR IP at 0x40000000 via AXI-Lite (devmem) +
# verifies its presence in the RX data path via iio_readdev.
#
# Register map (from xfir_hw.h):
#   0x40000000        ap_ctrl  (b0=ap_start, b2=ap_idle, b3=ap_ready, b7=auto_restart)
#   0x40000100–1FC    coeffs[0..127], packed: word n → bits[15:0]=coeffs[2n], [31:16]=coeffs[2n+1]
#
# Usage: sh fir_test.sh 2>&1 | tee /tmp/fir_test.log

BASE=0x40000000
COEF_BASE=0x40000100
N_WORDS=64          # 128 coeffs / 2 per word
IIO_URI="local:"
ADC_DEV="cf-ad9361-lpc"

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; }
info() { echo "[INFO] $*"; }
sep()  { echo ""; echo "=== $* ==="; }

dm_read()  { devmem "$1" 32 2>/dev/null; }
dm_write() { devmem "$1" 32 "$2" 2>/dev/null; }

hex() { printf '0x%08x' "$1" 2>/dev/null; }
add() { printf '0x%08x' $(( $1 + $2 )) 2>/dev/null; }

capture_bytes() {
    # $1 = timeout ms, $2 = n_samples
    rm -f /tmp/fir_cap.bin
    iio_readdev -u "$IIO_URI" -T "$1" -b 256 -s "$2" "$ADC_DEV" voltage0 \
        > /tmp/fir_cap.bin 2>/dev/null
    wc -c < /tmp/fir_cap.bin 2>/dev/null
}

nonzero_count() {
    # count non-zero bytes in last capture
    od -An -tu1 /tmp/fir_cap.bin 2>/dev/null | tr ' ' '\n' | grep -cv '^0$' | tr -d ' '
}

write_coefs() {
    # $1 = coef[0] value (16-bit signed as decimal), all others = 0
    # word 0: bits[15:0]=coef[0], bits[31:16]=coef[1]=0
    c0=$(( $1 & 0xFFFF ))
    dm_write "$COEF_BASE" "$(printf '0x%08x' $c0)"
    i=1
    while [ $i -lt $N_WORDS ]; do
        addr="$(add $COEF_BASE $(( i * 4 )))"
        dm_write "$addr" 0x00000000
        i=$(( i + 1 ))
    done
}

write_all_zero_coefs() {
    i=0
    while [ $i -lt $N_WORDS ]; do
        addr="$(add $COEF_BASE $(( i * 4 )))"
        dm_write "$addr" 0x00000000
        i=$(( i + 1 ))
    done
}

# ── 1. ap_ctrl status ──────────────────────────────────────────────────────
sep "ap_ctrl register (0x${BASE#0x})"
CTRL="$(dm_read $BASE)"
info "raw ap_ctrl = $CTRL"

if [ -z "$CTRL" ] || [ "$CTRL" = "ERR" ]; then
    fail "devmem read failed — check that 0x40000000 is mapped (devicetree UIO or /dev/mem)"
    exit 1
fi

CTRL_INT=$(( CTRL ))
AP_START=$(( (CTRL_INT >> 0) & 1 ))
AP_DONE=$(( (CTRL_INT >> 1) & 1 ))
AP_IDLE=$(( (CTRL_INT >> 2) & 1 ))
AP_READY=$(( (CTRL_INT >> 3) & 1 ))
AUTO_RST=$(( (CTRL_INT >> 7) & 1 ))

info "  ap_start    = $AP_START"
info "  ap_done     = $AP_DONE"
info "  ap_idle     = $AP_IDLE"
info "  ap_ready    = $AP_READY"
info "  auto_restart= $AUTO_RST"

if [ "$AUTO_RST" = "0" ]; then
    fail "auto_restart is OFF — filter will stall after first sample"
    info "  writing 0x81 (ap_start=1, auto_restart=1)"
    dm_write "$BASE" 0x00000081
    CTRL="$(dm_read $BASE)"
    info "  ap_ctrl after fix = $CTRL"
    AUTO_RST=$(( (CTRL) >> 7 & 1 ))
    [ "$AUTO_RST" = "1" ] && pass "auto_restart now ON" || fail "auto_restart still OFF — AXI-Lite write may be broken"
else
    pass "auto_restart is ON"
fi

# ── 2. Coefficient read-back (word 0) ─────────────────────────────────────
sep "Coefficient readback"
WORD0="$(dm_read $COEF_BASE)"
WORD1="$(dm_read "$(add $COEF_BASE 4)")"
WORD_LAST="$(dm_read "$(add $COEF_BASE $(( (N_WORDS-1)*4 )) )")"
info "coeffs word0  (c[0],c[1])   = $WORD0"
info "coeffs word1  (c[2],c[3])   = $WORD1"
info "coeffs word63 (c[126],c[127]) = $WORD_LAST"

# ── 3. Baseline RX capture ────────────────────────────────────────────────
sep "Baseline RX capture (current coefficients)"
BYTES="$(capture_bytes 3000 1024)"
NZ="$(nonzero_count)"
info "bytes captured = $BYTES, non-zero bytes = $NZ"
if [ "${BYTES:-0}" -gt 0 ] && [ "${NZ:-0}" -gt 0 ] 2>/dev/null; then
    pass "RX data flowing with current coefficients"
else
    fail "No data — check rebind_rx.sh first"
    exit 1
fi

# ── 4. Passthrough test (coeffs[0]=1, rest=0) ─────────────────────────────
sep "Passthrough coefficient test (c[0]=1, c[1..127]=0)"
info "Writing passthrough coefficients..."
write_coefs 1

# re-assert ap_start in case filter went idle during write
dm_write "$BASE" 0x00000081
sleep 1

BYTES_PT="$(capture_bytes 3000 1024)"
NZ_PT="$(nonzero_count)"
info "bytes = $BYTES_PT, non-zero bytes = $NZ_PT"
if [ "${BYTES_PT:-0}" -gt 0 ] && [ "${NZ_PT:-0}" -gt 0 ] 2>/dev/null; then
    pass "Data flows with passthrough coefficients"
else
    fail "No data with passthrough — possible AXI-Stream stall or TREADY issue"
fi

# ── 5. Zero filter test — proves filter IS in the data path ───────────────
sep "Zero coefficient test (all c[n]=0  =>  output must be 0)"
info "Writing all-zero coefficients..."
write_all_zero_coefs

dm_write "$BASE" 0x00000081
sleep 1

BYTES_Z="$(capture_bytes 3000 1024)"
NZ_Z="$(nonzero_count)"
info "bytes = $BYTES_Z, non-zero bytes = $NZ_Z"

if [ "${BYTES_Z:-0}" -gt 0 ] && [ "${NZ_Z:-0}" -eq 0 ] 2>/dev/null; then
    pass "All output bytes are zero — filter IS in the RX data path and working correctly"
elif [ "${NZ_Z:-0}" -gt 0 ] 2>/dev/null; then
    fail "Non-zero bytes with zero coefficients (non-zero=$NZ_Z) — filter may NOT be in the data path, or bypass is active"
else
    fail "No bytes captured at all"
fi

# ── 6. Restore passthrough ────────────────────────────────────────────────
sep "Restoring passthrough coefficients (c[0]=1)"
write_coefs 1
dm_write "$BASE" 0x00000081
BYTES_R="$(capture_bytes 2000 512)"
info "bytes after restore = $BYTES_R"
[ "${BYTES_R:-0}" -gt 0 ] 2>/dev/null && pass "RX restored" || fail "RX not restored"

sep "Done — copy /tmp/fir_test.log for further analysis"
