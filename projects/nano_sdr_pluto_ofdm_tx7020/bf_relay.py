"""Lab relay for the beamforming loop (TestTask006 3.2, milestones M1-M3 only): forwards the anchor's parameter messages
(beamd anchor on board B -> UDP to this PC) to the leader (beamd leader / single on board A1). Board B and A1 sit on different
USB networks (192.168.3.x / 192.168.2.x), the PC is on both. Logs every message (target epoch, parameters, SNR per antenna).
usage: python bf_relay.py [--listen 0.0.0.0:5005] [--to 192.168.2.1:5005] [--log logs/bf_relay.csv]"""
import argparse, socket, struct, time
from pathlib import Path

FMT = "<IIBBH" + "HHhHiI" * 4 + "4f2f"          # struct bf_msg in sw/beamd/beamd.c (little-endian, 100 bytes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:5005")
    ap.add_argument("--to", default="192.168.2.1:5005")
    ap.add_argument("--log", default=str(Path(__file__).parent / "logs" / "bf_relay.csv"))
    a = ap.parse_args()
    lh, lp = a.listen.split(":"); th, tp = a.to.split(":")
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); rx.bind((lh, int(lp)))
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    Path(a.log).parent.mkdir(parents=True, exist_ok=True)
    lf = open(a.log, "w")
    lf.write("t_s,seq,target_mod8,amp1,phase1,tau1,amp2,phase2,tau2,amp3,phase3,tau3,inc_b1,snr0,snr1,snr2,snr3,nu0,nu1\n")
    print(f"relay {a.listen} -> {a.to} (log {a.log}); Ctrl-C to stop")
    t0 = time.time(); n = 0
    while True:
        data, src = rx.recvfrom(256)
        tx.sendto(data, (th, int(tp)))
        n += 1
        if len(data) == struct.calcsize(FMT):
            v = struct.unpack(FMT, data)
            magic, seq, tgt = v[0], v[1], v[2]
            ch = [v[5 + 6 * i: 11 + 6 * i] for i in range(4)]        # amp, phase, tau, ctrl, rho, inc
            snr = v[29:33]; nu = v[33:35]
            lf.write(f"{time.time() - t0:.3f},{seq},{tgt}," + ",".join(f"{c[0]},{c[1]},{c[2]}" for c in ch[1:]) +
                     f",{ch[2][5]}," + ",".join(f"{s:.1f}" for s in snr) + "," + ",".join(f"{x:.2f}" for x in nu) + "\n")
            lf.flush()
            if n % 50 == 1:
                print(f"[{time.time() - t0:7.1f}s] msg {seq} -> epoch mod8 {tgt}  snr " + " ".join(f"{s:.1f}" for s in snr) +
                      f" dB  board nu {nu[0]:.1f} / {nu[1]:.1f} Hz")


if __name__ == "__main__":
    main()
