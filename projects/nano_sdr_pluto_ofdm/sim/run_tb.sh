#!/bin/bash
# usage: sim/run_tb.sh <tb_name> [extra xvlog args]
# Builds all RTL + the TB with Vivado xsim and runs it in sim/work (vectors copied from sim/vec).
# Exit code 0 only if the TB prints "TEST PASSED".
V=/c/AMDDesignTools/2025.2/Vivado/bin
SIM=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SIM")
TB=$1; shift
TBF=$(ls "$ROOT"/tb/*/"$TB".sv)
RTL="$ROOT/rtl/common/phy_pkg.sv"
for f in "$ROOT"/rtl/common/*.sv "$ROOT"/rtl/tx/*.sv "$ROOT"/rtl/rx/*.sv "$ROOT"/rtl/common/*.v "$ROOT"/rtl/tx/*.v "$ROOT"/rtl/rx/*.v; do
  [ -e "$f" ] && [ "$(basename "$f")" != phy_pkg.sv ] && RTL="$RTL $f"
done
mkdir -p "$SIM/work" && rm -rf "$SIM/work/vec" && cp -r "$SIM/vec" "$SIM/work/vec" && cd "$SIM/work" || exit 1
$V/xvlog.bat -sv $RTL $TBF "$@" > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
grep -E "^(ERROR|WARNING)" xvlog.log | grep -v "already analyzed" || true
# generics go through an args file (cmd .bat wrappers split on "=")
: > xelab.args; for g in $GENERIC; do echo "-generic_top $g" >> xelab.args; done
$V/xelab.bat -debug off --timescale 1ns/1ps -f xelab.args -s "${TB}_sim$$" "$TB" > xelab.log 2>&1 || { cat xelab.log; exit 1; }
OUT=$($V/xsim.bat "${TB}_sim$$" -runall)
echo "$OUT" | grep -E "TEST|mismatch|MISMATCH|ERROR|FATAL|not cleared|!=" | head -30
echo "$OUT" | grep -q "TEST PASSED"
