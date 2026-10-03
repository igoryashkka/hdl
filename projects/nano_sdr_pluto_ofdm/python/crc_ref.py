"""CRC-32 (IEEE), reflected, init FFFFFFFF. Register value (no final xor) -- matches phy_crc."""
import zlib
from phy_params import CRC32_INIT

def crc32_reg(data):
    return zlib.crc32(bytes(data), 0) ^ 0xFFFFFFFF if False else (zlib.crc32(bytes(data)) ^ 0xFFFFFFFF)

def append_crc(data):
    c = zlib.crc32(bytes(data))
    return list(data) + [(c >> (8 * i)) & 0xFF for i in range(4)]
