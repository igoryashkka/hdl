# plutolink — two-board OFDM PHY traffic generator and logger

One C program, two roles, run by hand on two Plutos (Nano SDR Pluto, Z010):

| board | bitstream / firmware | command |
|---|---|---|
| A (transmitter) | `nano_sdr_pluto_ofdm_tx` | `plutolink tx` |
| B (receiver)    | `nano_sdr_pluto_ofdm_rx` | `plutolink rx` |

TX builds packets (header + PRBS + CRC32, `nsyms × 550` bytes each) and streams them through DMA into the PL OFDM transmitter.
RX reads the decoded packet records from the PL receiver and logs, per packet: bit errors against the regenerated PRBS, CRC, EVM/SNR
(from the pilots), CFO, RSSI, timing index, CPE angle, plus once per second the hardware counters (detections, drops, ADC peak/clip,
sample rate). Because the TX puts its gain and step number into the payload, the RX log alone is enough to plot SNR / BER versus
TX gain.

## Safety

Use **cables and 30–60 dB of attenuation** between the boards for the first runs (start with `--gain -60` or lower). The AD9361
receiver is easily overloaded; an unattenuated 0 dBm-class TX next to the RX can damage it. Observe the radio rules of your country
before radiating (`--freq` default 2450 MHz).

## Build

```
make host test     # native build + selftest (packet builder/parser/statistics, no hardware)
make arm           # static ARM binary for the Pluto (arm-linux-gnueabihf-gcc, e.g. in WSL)
```
Copy `plutolink` to the board (`scp plutolink root@192.168.2.1:/tmp/`, password `analog`) and run it there as root.

## Images (ready in `fw/out/`, not committed)

`pluto_ofdm_tx.frm` (board A) and `pluto_ofdm_rx.frm` (board B): copy to the Pluto mass-storage drive, eject, wait for the reboot.
They are built by `fw/build_frm.sh` (`ROLE=rx|tx`, WSL as root) from the Vivado .xsa and the role device trees in `fw/dts/`.
`system_top_ofdm_{tx,rx}.bit/.xsa` are the raw bitstreams. Timing: TX WNS +0.52 ns, RX WNS +0.38 ns (Z010; RX slice usage 98.9 %).

## First steps on a board

```
./plutolink diag
```
prints the PHY register ID (RX/TX), the measured `l_clk` and sample strobe rates, the raw hardware counters and the AD9361 settings.
If it says `UNKNOWN`, the wrong bitstream is loaded; if the snapshot times out, `l_clk` is missing.

Receiver (board B):
```
./plutolink rx --freq 2450e6 --nsyms 2 --rx-gain 30 --log run1
```
Transmitter (board A), single gain, then a gain sweep:
```
./plutolink tx --freq 2450e6 --nsyms 2 --gain -60 --rate 200 --log run1
./plutolink tx --nsyms 2 --sweep -70:-30:5:500 --log run1      # 500 packets per 5 dB step, step_id increments
```
Start the RX first. `--nsyms`, `--seed` and `--freq` must be identical on both sides. Stop with Ctrl-C (a summary is printed).

## Options

```
common  --freq HZ  --nsyms N(1..8)  --seed N  --log PREFIX  --stats SEC  --duration SEC  --count N  --no-rf
tx      --gain DB  --rate PPS  --gap SAMPLES  --sweep FROM:TO:STEP:COUNT[:LOOPS]
rx      --rx-gain DB  --agc  --rmin N  --gain-sh N
```
* `--gap` (TX, default 16384 samples ≈ 0.53 ms): the receiver handles one packet at a time; the TX wrapper enforces this gap.
* `--rmin`: detector energy gate (default 262144 ≈ −16 dB below nominal level, see `rtl/rx/phy_sync_sc.sv`); `--gain-sh`: digital shift before the detector.
* `--no-rf`: leave the AD9361 as it is (e.g. configured by `iio_attr`).

## Logs (written next to the binary, copy them to the PC)

| file | content |
|---|---|
| `<prefix>_packets.csv` (rx) | per packet: `t_s, phy_seq, app_seq, hdr_ok, crc_ok, step_id, tx_gain_db, flags, bits, bit_errors, byte_errors, evm_pct, snr_db, cfo_hz, rssi_dbfs, cpe_deg, n_best, evm_sum, rssi_code` |
| `<prefix>_stats.csv` (rx) | 1 Hz: detections, packets, drops, watchdog, flags, ADC peak I/Q, ADC clip count, DMA beats/stalls, measured fs and l_clk |
| `<prefix>_packets.csv` (tx) | per packet: time, seq, step_id, gain_db, bytes, DMA write time |
| `<prefix>_stats.csv` (tx) | 1 Hz: accepted/done packets, overflow/trunc/underflow, bad headers, DAC sample counters, output peak, busy clocks |

`flags` (PHY): bit0 interleaver overflow, bit1 tracker overrun, bit2 FFT overflow, bit3 window armed late.

Analysis on the PC:
```
python analyze_logs.py run1 --tx run1 --out plots      # per-step table + snr_vs_gain / ber_vs_snr / time_series PNGs
```

## Measurement definitions

* **EVM / SNR** are derived from the 100 pilots per symbol after equalisation and common-phase correction
  (`evm_sum` = Σ |Δre|+|Δim|; EVM = 0.8862 · mean L1 / 12952, i.e. relative to the rms 16-QAM constellation, Gaussian assumption).
  `snr_db = −20·log10(EVM)`. This is an *in-band post-equaliser* SNR; it saturates around 30–35 dB (fixed-point noise floor).
* **RSSI** is the Schmidl-Cox window energy at the timing peak (1024 samples, after the 12-bit ADC and DC removal) in dB relative to
  a full-scale 12-bit sample (|x| = 2048). It is the power of the preamble, not of the whole packet; with PAPR ≈ 11 dB keep it below
  about −12 dBFS to avoid clipping.
* **CFO** = −cfo_inc · 30.72e6 / 2³² (fractional range only, ±15 kHz; the integer-CFO stage is not implemented).
* **BER** counts bits of the PRBS part of the payload; **PER** is the share of packets with a wrong CRC; packets that never arrive
  show up as sequence gaps (`lost`) and as `delivered < sent` per step in `analyze_logs.py`.

## How it talks to the hardware

* PHY registers: `/dev/mem` at `0x7C440000` (`rtl/common/phy_regs_axil.v`: control, 16 status words via a snapshot handshake).
* Packet stream: IIO buffer of `cf-ad9361-lpc` (RX) / `cf-ad9361-dds-core-lpc` (TX): channels `voltage0..` are enabled, the buffer
  block size is set to one packet record and records are re-synchronised on the header pattern (`A55A`, version 2) when anything gets out of step.
* AD9361: `ad9361-phy` sysfs attributes (sampling frequency 30.72 MS/s, bandwidth 20 MHz, LO, gains).

## Unverified on hardware (expect to iterate here first)

The whole chain is verified in simulation (RTL testbenches, bit-exact against the Python models); this program and the PL
register/DMA integration have **not yet run on a board**. Things most likely to need adjustment:
1. `l_clk` frequency / strobe pattern (check with `diag`; the PHY works with any clock ≥ 2 × sample rate),
2. IIO DMA block / `tlast` behaviour of the stream (the parser resynchronises, `resync bytes` in the summary tells if it was needed),
3. ADC sample format (the RX assumes the 12-bit value sign-extended in 16 bit; check `adc_peak` in the stats against the signal level),
4. TX gain / RX gain ranges of your board and front end.
