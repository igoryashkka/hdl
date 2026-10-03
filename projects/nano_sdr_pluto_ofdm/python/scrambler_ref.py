"""x^15+x^14+1 additive scrambler, MSB-first within byte (golden for phy_scrambler)."""
from phy_params import SCR_SEED

def scramble(data, seed=SCR_SEED):
    s = seed; out = []
    for byte in data:
        o = 0
        for i in range(7, -1, -1):
            fb = ((s >> 14) ^ (s >> 13)) & 1
            o |= (((byte >> i) & 1) ^ fb) << i
            s = ((s << 1) | fb) & 0x7FFF
        out.append(o)
    return out
