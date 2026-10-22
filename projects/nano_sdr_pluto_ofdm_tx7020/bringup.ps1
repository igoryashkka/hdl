# Bring-up of the OFDM PHY TX on the Zynq-7020 Pluto board, all steps in one go:
#   1. load the bitstream into the PL over JTAG (xsdb, Linux keeps running)
#   2. reload the AD9361 drivers on the board (the PL blocks were reset by the load)
#   3. copy plutolink to the board
#   4. run "plutolink diag" (expects PHY ID OFTX)
# usage (PowerShell, from this folder):
#   .\bringup.ps1                      all steps
#   .\bringup.ps1 -SkipProgram         steps 2-4 (bitstream already loaded)
#   .\bringup.ps1 -Ip 192.168.2.1 -Bit C:\path\system_top.bit
# The board password (default "analog") is asked by ssh / scp; two prompts at most.
param(
  [string]$Ip = "192.168.2.1",
  [string]$Bit = "",
  [switch]$SkipProgram
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$xsdb = "C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat"
$plutolink = Join-Path $here "..\nano_sdr_pluto_ofdm\sw\plutolink\plutolink"
$target = "root@$Ip"
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL")   # the board's host key changes with every firmware

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

if (-not $SkipProgram) {
  Step "1/4 bitstream -> PL (JTAG)"
  $tcl = Join-Path $here "program_pl_jtag.tcl"
  if ($Bit) { & $xsdb $tcl $Bit } else { & $xsdb $tcl }
  if ($LASTEXITCODE -ne 0) { throw "xsdb failed (exit $LASTEXITCODE): is the JTAG adapter connected and the board powered?" }
}

if (-not (Test-Path $plutolink)) { throw "plutolink binary not found: $plutolink (build it with 'make arm' in sw/plutolink)" }

Step "2/4 copy plutolink -> ${target}:/tmp/"
& scp @sshOpts $plutolink "${target}:/tmp/plutolink"
if ($LASTEXITCODE -ne 0) { throw "scp failed: is the board reachable at $Ip?" }

Step "3/4 reload the AD9361 drivers, 4/4 plutolink diag"
# one ssh session for both steps (one password prompt)
$remote = @'
chmod +x /tmp/plutolink
echo "-- unloading drivers"
modprobe -r cf_axi_dds cf_axi_adc ad9361_drv ad9361 2>/dev/null || echo "   (modprobe -r failed: drivers may be built into the kernel)"
sleep 1
echo "-- loading ad9361"
modprobe ad9361 2>/dev/null || echo "   (modprobe ad9361 failed: drivers may be built into the kernel)"
sleep 2
echo "-- IIO devices"
for d in /sys/bus/iio/devices/iio:device*; do echo "   $(basename $d): $(cat $d/name 2>/dev/null)"; done
echo "-- plutolink diag"
/tmp/plutolink diag
'@
# the script goes over stdin (PowerShell 5.1 mangles double quotes inside native arguments); carriage returns are stripped on the board
$remote | & ssh @sshOpts $target "tr -d '' > /tmp/bringup.sh; sh /tmp/bringup.sh"
if ($LASTEXITCODE -ne 0) { Write-Host "`nssh / diag returned $LASTEXITCODE" -ForegroundColor Yellow }

Write-Host "`nNext (cable + 30-60 dB attenuation first):" -ForegroundColor Green
Write-Host "  ssh $target /tmp/plutolink tx --freq 2450e6 --nsyms 2 --mode 0 --gain -60 --rate 200 --log run1"
