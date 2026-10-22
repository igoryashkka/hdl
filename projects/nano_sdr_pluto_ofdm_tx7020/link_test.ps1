# Two-board test: board A (our TX bitstream) transmits with plutolink, board B (stock firmware/bitstream) records IQ, the PC decodes
# the recording with the Python receiver models and checks the plutolink payloads (CRC32).
#   .\link_test.ps1                                     MAX RANGE, 2 symbols, TX -60 dB, RX gain 30 dB, 2 M samples (65 ms)
#   .\link_test.ps1 -Mode 1 -Gain -50 -RxGain 20
#   .\link_test.ps1 -RxIp 192.168.3.1 -TxIp 192.168.2.1
# Before: board A prepared with .\bringup.ps1; the two boards on different USB subnets (see README, "Two boards").
# Cable + 30-60 dB attenuation between the boards.
param(
  [string]$TxIp = "192.168.2.1",
  [string]$RxIp = "192.168.3.1",
  [int]$Mode = 0,
  [int]$Nsyms = 2,
  [double]$Gain = -60,          # TX attenuation, dB
  [double]$RxGain = 30,         # RX manual gain, dB
  [double]$Freq = 2450e6,
  [int]$Rate = 1000,            # packets per second (about 65 packets in a 65 ms recording)
  [int]$Samples = 2000000,      # recorded samples (30.72 MS/s)
  [string]$Name = "",
  [string]$Password = "analog"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$phySim = Join-Path $here "..\nano_sdr_pluto_ofdm\phy_sim"
$logs = Join-Path $here "logs"
New-Item -ItemType Directory -Force $logs | Out-Null
if (-not $Name) { $Name = "link_" + (Get-Date -Format "yyyyMMdd_HHmmss") }
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$env:TEMP\pluto_known_hosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")
$askpass = Join-Path $env:TEMP "pluto_askpass.cmd"
Set-Content -Path $askpass -Value "@echo $Password" -Encoding ASCII
$env:SSH_ASKPASS = $askpass; $env:SSH_ASKPASS_REQUIRE = "force"; $env:DISPLAY = "dummy:0"
function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. transmitter (background, a bit longer than the recording)
$txSeconds = [math]::Ceiling($Samples / 30.72e6) + 6
$txLog = Join-Path $logs "${Name}_tx_console.txt"
$txCmd = "cd /tmp && ./plutolink tx --freq $Freq --nsyms $Nsyms --mode $Mode --gain $Gain --rate $Rate --duration $txSeconds --log $Name"
Step "TX  root@${TxIp}: $txCmd"
$tx = Start-Process -FilePath "ssh" -ArgumentList ($sshOpts + @("root@$TxIp", $txCmd)) -NoNewWindow -PassThru -RedirectStandardOutput $txLog -RedirectStandardError "$txLog.err"
Start-Sleep -Seconds 3
if ($tx.HasExited) { Get-Content $txLog, "$txLog.err" -ErrorAction SilentlyContinue; throw "the transmitter stopped early (see above)" }

# ---------------------------------------------------------------- 2. recording on board B
Step "RX  root@${RxIp}: $Samples samples at 30.72 MS/s, LO $($Freq/1e6) MHz, gain $RxGain dB"
$rxScript = @"
P=`$(grep -l '^ad9361-phy$' /sys/bus/iio/devices/iio:device*/name | xargs dirname)
echo 30720000 > `$P/in_voltage_sampling_frequency
echo 18000000 > `$P/in_voltage_rf_bandwidth
echo $([int64]$Freq) > `$P/out_altvoltage0_RX_LO_frequency
echo manual > `$P/in_voltage0_gain_control_mode
echo $RxGain > `$P/in_voltage0_hardwaregain
sleep 0.5
echo "   fs `$(cat `$P/in_voltage_sampling_frequency)  LO `$(cat `$P/out_altvoltage0_RX_LO_frequency)  gain `$(cat `$P/in_voltage0_hardwaregain)  rssi `$(cat `$P/in_voltage0_rssi)"
iio_readdev -b 1048576 -s $Samples cf-ad9361-lpc voltage0 voltage1 > /tmp/$Name.iq && ls -l /tmp/$Name.iq
"@
$rxScript | & ssh @sshOpts "root@$RxIp" "tr -d '\r' | sh"
if ($LASTEXITCODE -ne 0) { throw "recording on $RxIp failed" }
& scp -O @sshOpts "root@${RxIp}:/tmp/$Name.iq" $logs
& ssh @sshOpts "root@$RxIp" "rm -f /tmp/$Name.iq"

# ---------------------------------------------------------------- 3. transmitter summary, logs
Step "TX summary"
$tx.WaitForExit()
Get-Content $txLog | Select-Object -Last 4
& scp -O @sshOpts "root@${TxIp}:/tmp/${Name}_*.csv" $logs 2>$null

# ---------------------------------------------------------------- 4. decoding on the PC
Step "decoding (Python receiver, bit-exact models of the RTL)"
Push-Location $phySim
python experiments/decode_capture.py (Join-Path $logs "$Name.iq") --mode $Mode --nsyms $Nsyms --out (Join-Path $logs "$Name.json")
Pop-Location
Remove-Item $askpass -ErrorAction SilentlyContinue
Write-Host "`nfiles: $logs\$Name.*" -ForegroundColor Green
