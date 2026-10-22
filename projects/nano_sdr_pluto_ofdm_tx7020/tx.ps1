# Runs the OFDM transmitter on the board with live output, then copies its logs to .\logs\.
#   .\tx.ps1                                  MAX RANGE, 2 symbols, -60 dB, 200 packets/s, 2450 MHz, until Ctrl-C
#   .\tx.ps1 -Mode 1 -Gain -40 -Seconds 30    MAX RATE, 30 s
#   .\tx.ps1 -Extra "--sweep -70:-30:5:500"   any further plutolink options
# Needs bringup.ps1 first (bitstream, drivers, plutolink in /tmp). Cable + 30-60 dB attenuation for the first runs.
param(
  [int]$Mode = 0,                 # 0 = MAX RANGE (QPSK, LDPC 1/2), 1 = MAX RATE (16-QAM, LDPC 5/6)
  [int]$Nsyms = 2,
  [double]$Gain = -60,            # TX attenuation, dB (0 .. -89.75)
  [double]$Freq = 2450e6,
  [int]$Rate = 200,               # packets per second
  [int]$Seconds = 0,              # 0 = until Ctrl-C
  [string]$Log = "run1",
  [string]$Extra = "",
  [string]$Ip = "192.168.2.1",
  [string]$Password = "analog"
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = "root@$Ip"
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=$env:TEMP\pluto_known_hosts", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")
Remove-Item "$env:TEMP\pluto_known_hosts" -ErrorAction SilentlyContinue   # boards change their host key with every boot / firmware
$askpass = Join-Path $env:TEMP "pluto_askpass.cmd"
Set-Content -Path $askpass -Value "@echo $Password" -Encoding ASCII
$env:SSH_ASKPASS = $askpass; $env:SSH_ASKPASS_REQUIRE = "force"; $env:DISPLAY = "dummy:0"

$cmd = "cd /tmp && ./plutolink tx --freq $Freq --nsyms $Nsyms --mode $Mode --gain $Gain --rate $Rate --log $Log"
if ($Seconds -gt 0) { $cmd += " --duration $Seconds" }
if ($Extra) { $cmd += " $Extra" }
Write-Host "== $cmd" -ForegroundColor Cyan
Write-Host "   (Ctrl-C stops the transmitter; the summary and the logs follow)" -ForegroundColor DarkGray
# -t: a terminal on the board, so the 1 s statistics appear immediately and Ctrl-C reaches plutolink
& ssh -t @sshOpts $target $cmd

$dst = Join-Path $here "logs"
New-Item -ItemType Directory -Force $dst | Out-Null
& scp -O @sshOpts "${target}:/tmp/${Log}_*.csv" $dst 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host "`nlogs: $dst\${Log}_packets.csv, ${Log}_stats.csv" -ForegroundColor Green }
Remove-Item $askpass -ErrorAction SilentlyContinue
