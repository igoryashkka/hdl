# Beamforming milestone M1 (TestTask006): two TX channels of board A, anchor on board B, PC relay (lab only).
#   .\bf_m1.ps1                    load the BF bitstream on A, then three runs of -Seconds each and a report:
#                                  ch0 (data on TX1 only), hold (TX1 + TX2, unit weights), bf (TX1 + TX2, anchor weights)
#   .\bf_m1.ps1 -SkipProgram       bitstream already loaded
#   .\bf_m1.ps1 -Runs bf           one run only
# Needs: antennas on A TX1 and TX2 (or a 2-way combiner + attenuator to B), B RX1, both boards on USB (A 192.168.2.1, B 192.168.3.1),
# python on the PC. Logs: .\logs\bf_m1_<run>_anchor.csv (B), bf_m1_<run>_relay.csv, bf_m1_<run>_single.csv (A).
param(
  [string]$TxIp = "192.168.2.1",
  [string]$RxIp = "192.168.3.1",
  [string]$PcIp = "192.168.3.10",
  [int]$Seconds = 30,
  [string[]]$Runs = @("ch0", "hold", "bf"),
  [double]$TxGain = -10,
  [double]$RxGain = 40,
  [double]$Freq = 2450e6,
  [switch]$SkipProgram,
  [string]$Password = "analog"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logs = Join-Path $here "logs"; New-Item -ItemType Directory -Force $logs | Out-Null
$beamd = Join-Path $here "..\nano_sdr_pluto_ofdm\sw\beamd\beamd"
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$env:TEMP\pluto_known_hosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")
Remove-Item "$env:TEMP\pluto_known_hosts" -ErrorAction SilentlyContinue
$askpass = Join-Path $env:TEMP "pluto_askpass.cmd"
Set-Content -Path $askpass -Value "@echo $Password" -Encoding ASCII
$env:SSH_ASKPASS = $askpass; $env:SSH_ASKPASS_REQUIRE = "force"; $env:DISPLAY = "dummy:0"
function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

if (-not $SkipProgram) {
  Step "board A: BF bitstream + drivers (bringup.ps1)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "bringup.ps1") -Ip $TxIp -Password $Password
}
Step "beamd -> A and B"
& scp -O @sshOpts $beamd "root@${TxIp}:/tmp/beamd"
& scp -O @sshOpts $beamd "root@${RxIp}:/tmp/beamd"
& ssh @sshOpts "root@$TxIp" "chmod +x /tmp/beamd"
& ssh @sshOpts "root@$RxIp" "chmod +x /tmp/beamd"

$relay = Start-Process -FilePath "python" -ArgumentList @((Join-Path $here "bf_relay.py"), "--to", "${TxIp}:5005", "--log", (Join-Path $logs "bf_m1_relay.csv")) -NoNewWindow -PassThru
try {
  foreach ($run in $Runs) {
    $txArgs = switch ($run) { "ch0" { "--data-mask 1 --hold" } "hold" { "--data-mask 3 --hold" } default { "--data-mask 3" } }
    Step "run '$run': anchor on B ($Seconds s), transmitter on A: beamd single $txArgs"
    $an = Start-Process -FilePath "ssh" -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $logs "bf_m1_${run}_anchor_console.txt") -ArgumentList ($sshOpts + @(
      "root@$RxIp", "/tmp/beamd anchor --nant 2 --freq $Freq --rx-gain $RxGain --relay ${PcIp}:5005 --seconds $($Seconds + 4) --log /tmp/bf_m1_$run"))
    Start-Sleep -Seconds 2
    & ssh -t @sshOpts "root@$TxIp" "/tmp/beamd single --freq $Freq --tx-gain $TxGain $txArgs --seconds $Seconds --log /tmp/bf_m1_$run"
    $an.WaitForExit()
    & scp -O @sshOpts "root@${RxIp}:/tmp/bf_m1_${run}_anchor.csv" $logs
    & scp -O @sshOpts "root@${TxIp}:/tmp/bf_m1_${run}_single.csv" $logs
  }
} finally {
  Stop-Process -Id $relay.Id -ErrorAction SilentlyContinue
}
Step "report"
python (Join-Path $here "bf_m1_report.py") --logs $logs
