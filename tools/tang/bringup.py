"""Bring-up checks of the Tang Nano 20K board (docs/tangnano20k.md):

    python tools/tang/bringup.py --port COM5 [--image OTPU.IMG] [--sdram-mib 4] [--speed]

1. the link and the registers (ID, build, configuration hash, CAPS, STATUS);
2. the SD card (initialized, SDHC) and the image file on it (its block, its size);
3. the SDRAM through the board's own paths: zero pages written, read back (copy on write);
4. with --speed: the card's read rate (line fills of 64 KiB);
5. a tiny program on the core (VOP, MM-free) against the ISA simulator.
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402

from opentpu import isa as I  # noqa: E402
from opentpu import target as T  # noqa: E402
from opentpu.host import tang as TG  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--image", default="OTPU.IMG")
    ap.add_argument("--sdram-mib", type=float, default=1)
    ap.add_argument("--speed", action="store_true")
    ap.add_argument("--sd", default=None, help="the card's bus: hs,POL,SAMP[,NEG] (tools/tang/sdtune.py) or 24 (default)")
    a = ap.parse_args()
    link = TG.TangLink(a.port, baud=a.baud)
    i = link.info()
    print(f"[1] board: build {i['build']:08x}, hash {i['hash']:08x} (host {T.arch_hash(T.config('tangnano20k')):08x}), "
          f"CAPS {i['caps']:08x}, {i['core_khz']} kHz, STATUS {link.reg_read(TG.R_STATUS):#x}")
    link.reg_write(TG.R_SCRATCH, 0x12345678)
    assert link.reg_read(TG.R_SCRATCH) == 0x12345678, "scratch register"
    try:
        i = link.wait_ready(timeout=5)
        print("[2] SD card ready")
        print(f"    bus: {link.sd_setup(a.sd or '24')}")          # (re-initialized: a card swapped meanwhile)
        i = link.info()
        print(f"    card: SDHC {i['sdhc']}")
        card = True
    except TG.TangError as e:
        print(f"[2] SD card: {e} (state {link.info()['sd_state']})")
        card = False
    lba = size = 0
    if card:
        try:
            lba, size = TG.find_image(link, a.image)
            print(f"    {a.image}: block {lba}, {size / 2**20:.1f} MiB, first words "
                  f"{[hex(x) for x in link.read_words(lba * 512, 4, raw=True)]}")
        except TG.TangError as e:
            print(f"    {a.image}: {e}")
    # [3] the SDRAM: an empty image (every page a zero page), patterns through COW pages
    link.wait_ready(timeout=5, card=False)
    link.set_image(0, 0)
    n = int(a.sdram_mib * 2**20) // 4
    rng = np.random.default_rng(1)
    pat = rng.integers(0, 2**32, n, dtype=np.uint64).astype(np.uint32)
    t0 = time.time()
    link.write_words(0, pat)
    t1 = time.time()
    back = link.read_words(0, n)
    t2 = time.time()
    bad = np.count_nonzero(back != pat)
    print(f"[3] SDRAM: {a.sdram_mib} MiB written ({n * 4 / (t1 - t0) / 1e3:.0f} kB/s) and read "
          f"({n * 4 / (t2 - t1) / 1e3:.0f} kB/s): {bad} words wrong, "
          f"{link.reg_read(TG.R_MAP_STATUS) & 0xFFFF} COW pages" + ("" if not bad else
          f"; first at {4 * int(np.argmax(back != pat)):#x}: {back[back != pat][0]:#x} "
          f"for {pat[back != pat][0]:#x}"))
    if a.speed and size:
        link.set_image(lba, size)
        f0 = link.reg_read(TG.R_LINE_FILLS)
        t0 = time.time()
        k = min(32, size // 65536)
        for j in range(k):
            link.read_words(j * 65536, 1)
        dt = time.time() - t0
        print(f"[4] card: {link.reg_read(TG.R_LINE_FILLS) - f0} line fills in {dt:.2f} s = "
              f"{k * 65536 / dt / 1e6:.1f} MB/s; reads restarted so far {link.reg_read(0x22C)}, "
              f"blocks lost {link.reg_read(TG.R_SD_CFG) >> 16}")
    # [5] a VOP on the core
    link.set_image(0, 0)
    x = rng.standard_normal(64).astype(np.float32)
    link.write_words(0x1000, x.view(np.uint32))
    prog = [I.ld(0x1000, 0, 64), I.vop(I.V_EXP2, 100, 0, 0, 1, 64, 64, 64, 0),
            I.vop(I.V_RSUM, 200, 100, 0, 1, 64, 1, 64, 0), I.st(0x2000, 100, 64),
            I.st(0x2100, 200, 1), I.halt()]          # (only words the program wrote: TMEM is not
                                                     # cleared between runs)
    w = I.assemble(prog)
    link.write_words(0x8000, w)
    st = link.run(0x8000, len(prog))
    got = np.concatenate([link.read_words(0x2000, 64), link.read_words(0x2100, 1)])
    from opentpu.isasim import Machine
    cfg = T.config("tangnano20k")
    dram = np.zeros(1 << 16, np.uint8)
    dram[0x1000:0x1100] = x.view(np.uint8)
    import dataclasses
    m = Machine(dataclasses.replace(cfg, DRAM_BYTES=1 << 16), [prog], [dram]).run()
    out = m.slices[0].dram
    want = np.concatenate([out[0x2000:0x2100].view(np.uint32), out[0x2100:0x2104].view(np.uint32)])
    print(f"[5] core: {st['cycles']} cycles, {st['instructions']} instructions, exp2 + rsum "
          f"{'bit-exact' if np.array_equal(got, want) else 'DIFFERENT'}")


if __name__ == "__main__":
    main()
