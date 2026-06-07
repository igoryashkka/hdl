# HW69 TX RTL Blocks

First-pass RTL for moving the GNU Radio TX path into PL.

## Blocks

- `hw69_tx_bitstream.sv` generates the current packet bitstream and burst gate.
- `hw69_pn9_whitener.sv` is a standalone PN9 payload whitener with seed `0x1ff`.
- `hw69_char_to_fixed.sv` is the fixed-point equivalent of `Char To Float` for 0/1 streams.
- `hw69_fixed_add_const.sv` implements the `Add Const -0.5` stage.
- `hw69_fixed_multiply_const.sv` implements the `Multiply Const 2.0` stage.
- `hw69_zoh_resampler.sv` is the `Rational Resampler` equivalent for the current `[1.0] * interp` zero-order hold behavior.
- `hw69_tx_shaping_lpf.sv` is the fixed-point TX shaping low-pass FIR.
- `hw69_frequency_modulator.sv` is the frequency-modulation phase accumulator for a DDS/NCO.
- `hw69_sin_cos_lut.sv` converts phase to Q1.15 cosine/sine with a synthesizable 12-bit phase-addressed LUT using interpolation over a compact 256-point full-wave table.
- `hw69_fsk_iq_modulator.sv` is the full RTL FSK modulator: fixed-point control to phase step, phase accumulation, and IQ generation.
- `hw69_tx_modulator_chain.sv` wires the packet source through scaling, resampling, LPF, and modulation.
- `hw69_fsk_control.sv` is kept as a small legacy helper that maps bits directly to mark/space control words.

## Packet Format Matched

- Preamble: `0xAA` repeated, default `80` bytes.
- Sync: `0x91D3`.
- Post-sync marker: `0x2DD4`, not whitened.
- Payload: `14` bytes, `11 22 33 44 55 <counter> 88-fill` before whitening.
- Counter: starts at `1`, big-endian, variable byte count like the Python TX packetizer.
- Whitening: PN9 seed `0x1ff`, payload only.
- Tail guard: default `24` repeated copies of the final whitened payload bit with gate high.
- Period: default `9600` bit slots, matching `19200 bps * 0.5 s`.

## Vivado Bring-Up Path

1. Add the files in this folder to a Vivado RTL project.
2. For the full GNU Radio-style TX path, use `hw69_tx_modulator_chain.sv` as the integration top.
3. Clock it at the sample rate (`1.92 MHz` in the current graph) or at a faster PL clock with an adjusted sample-enable wrapper.
4. `hw69_fsk_iq_modulator.sv` now integrates the DDS/NCO and Q1.15 IQ generation directly. The default deviation phase word is `78293675`, matching `35000 Hz` at `1.92 MHz` with a 32-bit phase accumulator.
5. The integrated chain also applies a default carrier phase word of `536870912`, which is `240 kHz` at `1.92 MHz`, so FSK deviation rides around a positive center frequency instead of reversing around DC.
6. `freq_control` and `shaped_freq_control` are Q2.16 signed fixed-point. `phase_word` is an unsigned 32-bit wraparound phase accumulator. `i_sample` and `q_sample` are signed Q1.15.
7. Use `gate_sample` as the burst multiplier/enabler after the DDS/NCO output, matching the graph's post-modulation burst gate.

Simulation tops live in `rtl/sim`:

- `tb_hw69_tx_bitstream.sv` checks the packet bytes.
- `tb_hw69_fsk_iq_modulator.sv` checks stable frequency generation, Binary FSK switching, and accumulator overflow with self-checking assertions.
- `tb_hw69_tx_packet_to_iq_trace.sv` traces the first preamble bits through symbol mapping, phase-step generation, and IQ samples so the byte-to-IQ path is explicit in simulation output.
- `tb_hw69_tx_modulator_chain.sv` checks that the full scaling/resampling/LPF/modulation chain produces phase, IQ, and gate samples.

## Byte To IQ Mapping

For each packet bit, the TX path does this:

1. `hw69_tx_bitstream.sv` emits serial bits MSB-first. For the preamble byte `0xAA`, that is `1 0 1 0 1 0 1 0`.
2. `hw69_char_to_fixed.sv` maps bit `1 -> +1.0` and bit `0 -> 0.0` in Q2.16.
3. `hw69_fixed_add_const.sv` applies `-0.5`, giving `+0.5` or `-0.5`.
4. `hw69_fixed_multiply_const.sv` applies `*2.0`, giving the final NRZ symbol `+1.0` or `-1.0`.
5. `hw69_tx_shaping_lpf.sv` smooths symbol edges, so `shaped_freq_control` is the instantaneous FSK control waveform.
6. `hw69_frequency_modulator.sv` converts that control value into `phase_step = CARRIER_PHASE_WORD + shaped_freq_control * DEVIATION_PHASE_WORD`.
7. `hw69_sin_cos_lut.sv` converts the accumulated phase into `I = cos(phase)` and `Q = sin(phase)` in Q1.15.

So the packet bytes are not converted directly into IQ amplitudes. They are converted into a stream of bits, then into bipolar frequency-control symbols, then into phase increments, and only then into IQ samples.