"""Regenerates the simulation vectors sim/pkt<k>_iq.txt (+ _meta/_exp) from a capture and the C decoder CSV.

    python gen_vectors.py <capture.iq> <hopdet_decoded.csv> [n_packets]

capture.iq : raw int16 I/Q, Fs 4.5 MS/s, LO 867.4 MHz (the 59-alarm recording used in the project)
decoded.csv: output of `hopdet --file capture.iq --csv decoded.csv` (valid alarms have crc8_ok == 1)
"""
import csv, sys
import numpy as np

FS, LO, DUR = 4.5e6, 867.4e6, 0.01196
iq_path, csv_path = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 6
raw = np.fromfile(iq_path, dtype=np.int16).reshape(-1, 2)
rows = [r for r in csv.DictReader(open(csv_path)) if r["crc8_ok"] == "1"]
for k in range(n):
    r = rows[k]
    t0 = float(r["time_s"])
    s0, cnt = int((t0 - 2e-3) * FS), int((DUR + 4e-3) * FS)
    np.savetxt(f"pkt{k}_iq.txt", raw[s0:s0 + cnt], fmt="%d")
    fc = int(r["frequency_hz"]) - int(LO)
    open(f"pkt{k}_meta.txt", "w").write(f"{int(round(fc / FS * 2**32)) & 0xFFFFFFFF:08x}\n")
    open(f"pkt{k}_exp.mem", "w").write("\n".join(f"{b:02x}" for b in bytes.fromhex(r["dewhitened_bytes"])[:16]) + "\n")
    print(k, "t", t0, "fc_bb", fc)
