"""A FAT32 card image holding files, contiguous (for the virtual board, sim/tang): an MBR with
one partition at block 2048, 4 KiB clusters, the files in the root directory (8.3 names).

    python tools/tang/fatimg.py card.img OTPU.IMG=path/to/image ...
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

PART = 2048          # the partition's first block
SPC = 8              # blocks a cluster


def build(files: dict[str, bytes]) -> bytes:
    nclu_data = sum(-(-len(b) // (512 * SPC)) for b in files.values()) + 16
    nclu = max(nclu_data, 65525 + 16)                   # FAT32 needs >= 65525 clusters
    fatsz = -(-(nclu + 2) * 4 // 512)
    rsv, nfat = 32, 2
    total = rsv + nfat * fatsz + nclu * SPC
    vol = bytearray(total * 512)
    bs = bytearray(512)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", bs, 11, 512, SPC, rsv, nfat, 0, 0, 0xF8, 0, 63, 255, PART, total)
    struct.pack_into("<IHHIHH", bs, 36, fatsz, 0, 0, 2, 1, 6)
    bs[66] = 0x29
    bs[71:82] = b"OTPU       "
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xAA"
    vol[0:512] = bs
    fat = [0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF]          # media, reserved, root (one cluster)
    root = bytearray(512 * SPC)
    nxt = 3
    data = {}
    for i, (name, b) in enumerate(files.items()):
        n = max(1, -(-len(b) // (512 * SPC)))
        first = nxt
        for c in range(first, first + n):
            fat.append(c + 1 if c < first + n - 1 else 0x0FFFFFFF)
        nxt += n
        base, ext = (name.upper().split(".") + [""])[:2]
        e = bytearray(32)
        e[0:8] = base.ljust(8).encode()[:8]
        e[8:11] = ext.ljust(3).encode()[:3]
        e[11] = 0x20
        struct.pack_into("<HHI", e, 20, first >> 16, 0, 0)
        struct.pack_into("<HI", e, 26, first & 0xFFFF, len(b))
        root[32 * i:32 * i + 32] = e
        data[first] = b
    fatb = struct.pack(f"<{len(fat)}I", *fat)
    for k in range(nfat):
        o = (rsv + k * fatsz) * 512
        vol[o:o + len(fatb)] = fatb
    d0 = (rsv + nfat * fatsz) * 512
    vol[d0:d0 + len(root)] = root                       # cluster 2

    for first, b in data.items():
        o = d0 + (first - 2) * SPC * 512
        vol[o:o + len(b)] = b
    mbr = bytearray(512)
    struct.pack_into("<B3sB3sII", mbr, 446, 0, b"\0\0\0", 0x0C, b"\0\0\0", PART, total)
    mbr[510:512] = b"\x55\xAA"
    return bytes(mbr) + bytes((PART - 1) * 512) + bytes(vol)


if __name__ == "__main__":
    out = sys.argv[1]
    files = {}
    for a in sys.argv[2:]:
        n, p = a.split("=", 1)
        files[n] = Path(p).read_bytes()
    Path(out).write_bytes(build(files))
