"""The SD card's bus settings on the board: the reads of a few 64 KiB lines in high speed (48 MHz)
for each clock phase and sampling delay, against the same lines read at 24 MHz.

    python tools/tang/sdtune.py --port COM6 [--lines 8]

The settings that pass are printed; pass the chosen one to the host tools as
--sd hs,POL,SAMP (or "24" for the default bus).
"""
import argparse
import hashlib
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import tools.tang.winshim  # noqa: E402,F401
from opentpu.host import tang as TG  # noqa: E402


def lines_md5(link, first, n):
    """The md5s of n lines of the card (raw reads from block `first`), read from the card."""
    link.reg_write(TG.R_MAP, 1)                 # the line cache cleared: the reads go to the card
    while link.reg_read(TG.R_MAP) & 1:
        time.sleep(0.01)
    t0 = time.time()
    out = [hashlib.md5(link.read_card(first + 128 * k, 1) +
                       link.read_card(first + 128 * k + 127, 1)).hexdigest()[:8] for k in range(n)]
    return out, time.time() - t0


def speed(link, n=32):
    """MB/s of line fills (a word of each line)."""
    link.reg_write(TG.R_MAP, 1)
    while link.reg_read(TG.R_MAP) & 1:
        time.sleep(0.01)
    f0, t0 = link.reg_read(TG.R_LINE_FILLS), time.time()
    for k in range(n):
        link.read_words((2048 + 128 * k) * 512, 1, raw=True)
    return (link.reg_read(TG.R_LINE_FILLS) - f0) * 65536 / (time.time() - t0) / 1e6


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--lines", type=int, default=8)
    a = ap.parse_args()
    link = TG.TangLink(a.port, baud=a.baud)
    link.sd_config(reinit=True)
    ref, _ = lines_md5(link, 2048, a.lines)
    again, _ = lines_md5(link, 2048, a.lines)
    print(f"24 MHz: {'stable' if again == ref else 'UNSTABLE'}, {speed(link):.1f} MB/s")
    good = []
    for pol, samp, neg in [(p, s, n) for p in (0, 1) for s in range(4) for n in (0, 1)]:
        link.sd_config(reinit=True)
        t0 = link.sd_config()["timeouts"]
        st = link.sd_config(hs=True, pol=pol, samp=samp, neg=neg)
        if not st["hs"]:
            print(f"hs pol {pol} samp {samp} neg {neg}: the card did not switch (CMD6 result {st['cmd6']:#x})")
            if st["cmd6"] == 0xF:
                print("the card has no high speed mode")
                link.sd_config(reinit=True)
                return
            continue
        got, _ = lines_md5(link, 2048, a.lines)
        ok = sum(g == r for g, r in zip(got, ref))
        tmo = link.sd_config(hs=True, pol=pol, samp=samp, neg=neg)["timeouts"] - t0
        mbs = speed(link) if ok == a.lines else 0
        print(f"hs pol {pol} samp {samp} neg {neg}: {ok}/{a.lines} lines right, timeouts {tmo}"
              + (f", {mbs:.1f} MB/s" if mbs else ""), flush=True)
        if ok == a.lines and tmo == 0:
            good.append((pol, 2 * samp - neg, mbs))   # (the delay in half cycles)
    link.sd_config(reinit=True)
    if good:
        # the clock phase with the most passing delays, and the middle one of those
        p = max((0, 1), key=lambda q: sum(1 for g in good if g[0] == q))
        hs_ = sorted(g[1] for g in good if g[0] == p)
        h = hs_[(len(hs_) - 1) // 2]
        samp, neg = (h + 1) // 2, (h + 1) // 2 * 2 - h
        print(f"passing (pol, half cycles): {[(p_, h_) for p_, h_, _ in good]}; "
              f"use --sd hs,{p},{samp},{neg}")
    else:
        print("no high speed setting passed: keep the 24 MHz bus")


if __name__ == "__main__":
    main()
