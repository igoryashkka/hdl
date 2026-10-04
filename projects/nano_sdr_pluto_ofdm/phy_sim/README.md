# phy_sim — Python/RTL OFDM PHY validation framework

Python orchestrates, the **real RTL** (or the bit-exact Python model of it, or hardware) is the device under test. One scenario file
runs unchanged on every backend combination:

```
TX backend (python | rtl | pluto) -> RF channel model -> RX backend (python[fixed|float] | rtl | pluto) -> metrics / plots / report
```

| backend | what it is |
|---|---|
| `python` TX | the bit-exact fixed-point TX model of the RTL project (`python/tx_ref.py`), used as golden reference |
| `python` RX `mode: fixed` | bit-exact model of the RTL receiver (`rx_fixed_ref`, `sync_ref`, `rx_blocks_ref`) |
| `python` RX `mode: float` | floating-point algorithm reference (`rx_ref`) |
| `rtl` TX / RX | `phy_tx_top` / `phy_rx_top` simulated with the **Vivado simulator (xsim)** through file-driven testbenches (`tb/system/tb_rtl_{tx,rx}_file.sv`); Python writes the stimulus, parses the logs |
| `pluto` | pyadi-iio skeleton (Python PHY over the stock Pluto firmware) — **untested, not run on hardware** |

The existing Python reference models are imported (not reimplemented); `phy_sim/refs.py` locates them (`PHYSIM_REFS` overrides).

## Quick start

```bash
pip install -e .[test]                         # numpy scipy matplotlib pyyaml (+ pytest)
python -m phy_sim run scenarios/basic.yaml                      # python TX -> python RX
python -m phy_sim run scenarios/full_loopback.yaml --tx rtl --rx rtl      # RTL TX -> channel -> RTL RX (xsim, ~30 s)
python -m phy_sim run cfo --rx rtl --set 'rx.compare_with=["python:fixed"]'   # RTL RX vs bit-exact Python model
python -m phy_sim sweep scenarios/cfo_sweep_sweep.yaml          # SNR x CFO -> BER / PER / EVM / sync heatmaps
python -m phy_sim replay results/basic/capture                  # re-run the RX on a stored IQ capture (no channel simulation)
python -m phy_sim regression                                    # 11 scenarios with pass/fail criteria
python -m phy_sim unit                                          # RTL block/system testbench regression (xsim)
python -m pytest -q                                             # 27 unit/phy/regression tests (+ RTL tests marked `rtl`)
```

Vivado location: `rtl.vivado_dir` in the scenario or `PHYSIM_VIVADO` (default `C:\AMDDesignTools\2025.2\Vivado\bin`).
The testbench is compiled once per source change (cached in `results/_xsim`).

## Scenario format (YAML)

```yaml
experiment: {name: full_loopback, seed: 11, n_packets: 2, packet_gap: 12000, lead_samples: 1500}
payload: {nsyms: 2}                       # nsyms x 550 bytes per packet
tx: {backend: python}                     # python | rtl | pluto
rx: {backend: python, mode: fixed}        # python(fixed|float) | rtl | pluto ;  compare_with: [python:fixed]
channel:                                  # every impairment optional
  snr_db: 30            # + snr_definition: sample | esn0 | ebn0
  cfo_hz: 2000
  timing_offset: 20     # + fractional_delay, sfo_ppm
  multipath: [{delay: 0, gain_db: 0}, {delay: 11, gain_db: -6, phase_deg: 45}]
  # fading: {type: rician, doppler_hz: 20, k_factor_db: 8, delays: [0,10], powers_db: [0,-6]}
  # phase_noise: {linewidth_hz: 100}   iq_imbalance: {gain_db: .3, phase_deg: 2}   pa: {ibo_db: 6, am_pm_deg: 5}
  # interference: {type: tone|noise|iq, sir_db: 10, freq_hz: 1e6}
  # adc: {bits: 12, rms: 600, clip: true, dc_offset_i: 0, dc_offset_q: 0}      # AGC scale + quantisation + clipping
criteria: {max_ber: 1e-4, max_per: 0, max_evm_percent: 6, max_cfo_error_hz: 100, max_timing_error_samples: 45}
sweep: {snr_db: {start: 10, stop: 30, step: 5}, cfo_hz: {values: [0, 1000, 5000]}}     # optional, `trials:` repeats per point
```

## Result layout (`results/<name>/`, TZ §28)

`config.yaml, payload.bin, tx/iq.npy, channel/iq.npy, rx/{iq,fft,sync,channel}.npy, rx/events.json, trace/ (every recorded signal
with dtype/shape/sample rate/source), plots/{waveform,spectrum,waterfall,synchronization,constellation,channel_estimate,ofdm}.png,
metrics.json, report.html` and `capture/{rx.iq,tx.iq,channel.iq,payload.bin,metadata.json}` (int16 interleaved IQ + config + ground truth,
input of `replay`).

Metrics: BER/SER/PER, EVM rms/peak, MER, PAPR, crest factor, occupied bandwidth, subcarrier SNR, CPE, ICI proxy (null-bin level),
CFO and timing estimation error against the injected ground truth, channel-estimation MSE (|H_est| vs the true channel response, gain
and window delay fitted out), RTL latency / throughput / underflow / overflow, optional Vivado utilisation and timing
(`analysis/performance.parse_vivado_reports`).

## RTL-vs-Python comparison

`rx.compare_with` runs a second RX on the same IQ and checks: packet count and payload (bit exact), detector `n_best` and NCO
increment `cfo_inc` (**bit exact**), equalised constellation (tolerance: the NCO phase origin differs by a few samples between
the model and the RTL). Block-level bit-exact checks live in the 63 self-checking testbenches of the RTL project (`phy_sim unit`).

## Verified on this machine

* 27 pytest tests, 11 regression scenarios (python backends), sweep + heatmaps, replay.
* RTL TX output equals the Python TX model sample for sample (8768/8768); RTL RX reproduces the model's detector events and CFO
  increments bit-exactly; TX(rtl) -> channel -> RX(rtl) with 2 packets passes `full_loopback` (BER 0, PER 0, EVM 4.5 %).

## Known limitations / honest notes

* Verilator + cocotb (named in the TZ) are not installed here; xsim with file-driven testbenches is used instead. Cycle-accurate
  AXI-Lite register access does not exist because the RTL has no register interface yet (configuration = module parameters /
  testbench generics: `nsyms`, `rmin`, `gain_sh`, `gain`).
* The RTL receiver handles **one packet at a time**: packets must be spaced (`experiment.packet_gap`, default 12000 samples; the
  RTL TX would emit them back to back otherwise and the second packet is lost). Finding the minimum gap is a sweep away.
* Receiver CFO range is the fractional range only (+-15 kHz); the integer-CFO stage is not implemented in the RTL.
* The RTL packet interface does not return the per-bin FFT/equalizer debug of the Python model; the RTL backend exports the derotated data
  bins (`Q`) and the channel weights (`W`) from internal signals in simulation.
* At CFO >= 10 kHz the sweep shows an isolated single bit error per packet at 20/30 dB (not at 25 dB) — not investigated yet.
* Pluto backend: untested skeleton, uses the stock firmware path (IQ over USB), not the custom DMA packet builds.
