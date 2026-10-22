# Bring-up of the OFDM PHY TX on the Zynq-7020 Pluto board, all steps in one go:
#   1. load the bitstream into the PL over JTAG (xsdb, Linux keeps running)
#   2. reload the AD9361 drivers on the board (the PL blocks were reset by the load)
#   3. copy plutolink to the board
#   4. run "plutolink diag" (expects PHY ID OFTX)
# usage (PowerShell, from this folder):
#   .\bringup.ps1                      all steps
#   .\bringup.ps1 -SkipProgram         steps 2-4 (bitstream already loaded)
#   .\bringup.ps1 -Ip 192.168.2.1 -Bit C:\path\system_top.bit -Password analog
# The board password is passed to ssh / scp through SSH_ASKPASS (no prompt). scp uses -O (the board has no sftp-server).
param(
  [string]$Ip = "192.168.2.1",
  [string]$Bit = "",
  [string]$Password = "analog",
  [switch]$SkipProgram
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$xsdb = "C:\AMDDesignTools\2025.2\Vivado\bin\xsdb.bat"
$plutolink = Join-Path $here "..\nano_sdr_pluto_ofdm\sw\plutolink\plutolink"
$target = "root@$Ip"
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "ConnectTimeout=10")   # the board's host key changes with every firmware

# password without a prompt: ssh / scp run the SSH_ASKPASS program and read the password from its output
$askpass = Join-Path $env:TEMP "pluto_askpass.cmd"
Set-Content -Path $askpass -Value "@echo $Password" -Encoding ASCII
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = "force"
$env:DISPLAY = "dummy:0"

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

if (-not $SkipProgram) {
  Step "1/4 bitstream -> PL (JTAG)"
  $tcl = Join-Path $here "program_pl_jtag.tcl"
  if ($Bit) { & $xsdb $tcl $Bit } else { & $xsdb $tcl }
  if ($LASTEXITCODE -ne 0) { throw "xsdb failed (exit $LASTEXITCODE): is the JTAG adapter connected and the board powered?" }
}

if (-not (Test-Path $plutolink)) { throw "plutolink binary not found: $plutolink (build it with 'make arm' in sw/plutolink)" }

Step "2/4 copy plutolink -> ${target}:/tmp/"
& scp -O @sshOpts $plutolink "${target}:/tmp/plutolink"
if ($LASTEXITCODE -ne 0) { throw "scp failed: is the board reachable at ${Ip}?" }

Step "3/4 reload the AD9361 drivers, 4/4 plutolink diag"
# one ssh session for both steps
$remote = @'
chmod +x /tmp/plutolink
# the AD9361 drivers are built into the kernel: re-probe them through sysfs (unbind / bind), as in projects/pluto/full_reprobe_rx.sh
unbind() { [ -e "/sys/bus/$1/drivers/$2/$3" ] && echo "$3" > "/sys/bus/$1/drivers/$2/unbind" && echo "   unbind $2 $3"; }
bind()   { [ -e "/sys/bus/$1/drivers/$2/$3" ] || { echo "$3" > "/sys/bus/$1/drivers/$2/bind" && echo "   bind   $2 $3"; }; }
echo "-- re-probing the AD9361 drivers"
unbind platform cf_axi_adc 79020000.cf-ad9361-lpc
unbind platform cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
unbind platform dma-axi-dmac 7c400000.dma
unbind platform dma-axi-dmac 7c420000.dma
unbind spi ad9361 spi0.0
sleep 1
bind spi ad9361 spi0.0
sleep 2
bind platform dma-axi-dmac 7c400000.dma
bind platform dma-axi-dmac 7c420000.dma
bind platform cf_axi_dds 79024000.cf-ad9361-dds-core-lpc
bind platform cf_axi_adc 79020000.cf-ad9361-lpc
sleep 1
# the PHY runs at 30.72 MS/s (l_clk 122.88 MHz in 2R2T, inside the 8 ns constraint); after the re-probe the driver is at 61.44 MS/s (l_clk 245.76 MHz)
P=$(grep -l "^ad9361-phy$" /sys/bus/iio/devices/iio:device*/name | xargs dirname)
echo 30720000 > $P/in_voltage_sampling_frequency && echo "   sampling frequency $(cat $P/in_voltage_sampling_frequency)"
sleep 1
echo "-- IIO devices"
for d in /sys/bus/iio/devices/iio:device*; do echo "   $(basename $d): $(cat $d/name 2>/dev/null)"; done
echo "-- plutolink diag"
/tmp/plutolink diag
'@
# the script goes over stdin (PowerShell 5.1 mangles double quotes inside native arguments); carriage returns are stripped on the board
$remote | & ssh @sshOpts $target "tr -d '\r' > /tmp/bringup.sh; sh /tmp/bringup.sh"
if ($LASTEXITCODE -ne 0) { Write-Host "`nssh / diag returned $LASTEXITCODE" -ForegroundColor Yellow }

Write-Host "`nNext (cable + 30-60 dB attenuation first):" -ForegroundColor Green
Write-Host "  ssh $target /tmp/plutolink tx --freq 2450e6 --nsyms 2 --mode 0 --gain -60 --rate 200 --log run1"
Remove-Item $askpass -ErrorAction SilentlyContinue
