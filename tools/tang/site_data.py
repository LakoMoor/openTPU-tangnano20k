"""The silicon view of the GitHub Pages site (site/): where nextpnr put every cell of the design on
the GW2AR-18 and which wires it routed, by module, from build/tangnano20k/pnr.json.

    python tools/tang/site_data.py [--pnr build/tangnano20k/pnr.json] [--out site]

Writes site/data/silicon.json (tiles: cell counts per module; routing: segments per module,
counted) and site/img/floorplan.png (the same, static, for the README).
"""
import argparse
import collections
import json
import re
from pathlib import Path

# module groups: (name prefix, label, colour); the first prefix that matches wins
GROUPS = [
    ("u_core.u_mm", "MXU (matrix unit)", "#e4572e"),
    ("u_core.u_vpu", "VPU (vector unit)", "#f3a712"),
    ("u_core.u_fma", "fp32 multiply-add", "#ffd166"),
    ("u_core.u_comp", "exp2 / recip / rsqrt / log2", "#c9a227"),
    ("u_core.u_quant", "quantizer (QACT / QST)", "#a8c256"),
    ("u_core.u_seq", "sequencer + IMEM", "#29bf12"),
    ("u_core.u_dma", "DMA (LD / ST / WAITW)", "#1b998b"),
    ("u_core.tmem", "TMEM", "#3e8ed0"),
    ("u_core.g_act", "ACT RAM", "#6fa8dc"),
    ("u_core", "core glue", "#8e9aaf"),
    ("u_mem", "memory system (page table, SD cache, COW)", "#9b5de5"),
    ("u_sdram", "SDRAM controller", "#f15bb5"),
    ("u_sd", "SD card (4-bit, CRC16)", "#00bbf9"),
    ("u_host", "UART host link", "#00f5d4"),
    ("", "clocks, I/O, other", "#5c677d"),
]
DIRS = {"N": (0, -1), "S": (0, 1), "E": (1, 0), "W": (-1, 0)}
WIRE = re.compile(r"^([NSEW])([128])(\d)(\d)$")


def group(name: str) -> int:
    for i, (p, _, _) in enumerate(GROUPS):
        if name.startswith(p):
            return i
    return len(GROUPS) - 1


def tile(s: str):
    m = re.match(r"X(\d+)Y(\d+)", s)
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pnr", default="build/tangnano20k/pnr.json")
    ap.add_argument("--out", default="site")
    ap.add_argument("--log", default="build/tangnano20k/nextpnr.log")
    a = ap.parse_args()
    top = json.load(open(a.pnr))["modules"]["top"]
    W = H = 0
    tiles = collections.defaultdict(lambda: collections.Counter())   # (x, y) -> group -> cells
    kinds = collections.defaultdict(collections.Counter)             # group -> cell kind -> n
    bsram = []
    for name, c in top["cells"].items():
        bel = c["attributes"].get("NEXTPNR_BEL")
        if not bel:
            continue
        x, y = tile(bel)
        W, H = max(W, x + 1), max(H, y + 1)
        g = group(name)
        t = c["type"]
        kind = ("LUT" if t.startswith(("LUT", "MUX2")) else "FF" if t.startswith("DFF") else
                "ALU" if t == "ALU" else "BSRAM" if t in ("DP", "SDP", "DPX9", "SDPX9") else
                "LUTRAM" if t.startswith("RAM16") else "IO" if "BUF" in t else "other")
        kinds[g][kind] += 1
        if kind == "BSRAM":
            bsram.append([x, y, g])
        else:
            tiles[(x, y)][g] += 1
    segs = collections.Counter()                                     # (group, x0, y0, x1, y1)
    for name, net in top["netnames"].items():
        r = net["attributes"].get("ROUTING", "")
        if not r.strip():
            continue
        g = group(name)
        f = r.split(";")
        for i in range(0, len(f) - 2, 3):
            pip = f[i + 1]
            if not pip:
                continue
            parts = pip.split("/")
            if len(parts) != 3:
                continue
            x, y = tile(parts[0])
            m = WIRE.match(parts[2])                                # the pip's source wire
            if not m:
                continue
            d, hops = DIRS[m.group(1)], int(m.group(4))
            if hops == 0:
                continue
            x0, y0 = x - d[0] * hops, y - d[1] * hops
            segs[(g, x0, y0, x, y)] += 1
    out = Path(a.out)
    (out / "data").mkdir(parents=True, exist_ok=True)
    (out / "img").mkdir(parents=True, exist_ok=True)
    util = {}                                       # nextpnr's own utilisation
    if Path(a.log).exists():
        for m in re.finditer(r"^Info:\s+(\w+):\s+(\d+)/\s*(\d+)", Path(a.log).read_text(errors="ignore"), re.M):
            util[m.group(1)] = [int(m.group(2)), int(m.group(3))]
        f = re.findall(r"Max frequency for clock 'clk': ([\d.]+) MHz", Path(a.log).read_text(errors="ignore"))
        if f:
            util["fmax_mhz"] = float(f[-1])
    data = {
        "device": "GW2AR-LV18QN88C8/I7", "w": W, "h": H, "util": util,
        "groups": [{"label": l, "color": c, "cells": dict(kinds[i])} for i, (_, l, c) in enumerate(GROUPS)],
        "tiles": [[x, y, [[g, n] for g, n in cnt.items()]] for (x, y), cnt in sorted(tiles.items())],
        "bsram": bsram,
        "segs": [[g, x0, y0, x1, y1, n] for (g, x0, y0, x1, y1), n in segs.items()],
    }
    (out / "data" / "silicon.json").write_text(json.dumps(data, separators=(",", ":")))
    print(f"{W}x{H} tiles, {len(data['tiles'])} with logic, {len(bsram)} BSRAM, "
          f"{len(segs)} routing segments ({sum(segs.values())} pips)")
    try:
        _png(data, out / "img" / "floorplan.png")
    except ImportError:
        print("(no matplotlib: no floorplan.png)")


def _png(data, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection
    from matplotlib.patches import Rectangle
    W, H, G = data["w"], data["h"], data["groups"]
    fig, ax = plt.subplots(figsize=(10, 10 * H / W + 1.6), dpi=150)
    fig.patch.set_facecolor("#0b0f17")
    ax.set_facecolor("#0b0f17")
    lines = collections.defaultdict(list)
    for g, x0, y0, x1, y1, n in data["segs"]:
        lines[g].append([(x0 + .5, y0 + .5), (x1 + .5, y1 + .5)])
    for g, ls in lines.items():
        ax.add_collection(LineCollection(ls, colors=G[g]["color"], linewidths=.25, alpha=.18))
    for x, y, cnt in data["tiles"]:
        g = max(cnt, key=lambda e: e[1])[0]
        n = sum(e[1] for e in cnt)
        ax.add_patch(Rectangle((x + .08, y + .08), .84, .84, color=G[g]["color"],
                               alpha=min(1, .25 + n / 30), lw=0))
    for x, y, g in data["bsram"]:
        ax.add_patch(Rectangle((x + .02, y + .02), 2.9, .96, fill=False, ec=G[g]["color"], lw=1.2))
    ax.set_xlim(0, W)
    ax.set_ylim(H, 0)
    ax.set_aspect("equal")
    ax.axis("off")
    used = [(gg["label"], gg["color"]) for gg in G if sum(gg["cells"].values())]
    for i, (l, c) in enumerate(used):
        fig.text(.02 + .33 * (i % 3), .085 - .016 * (i // 3), "■ " + l, color=c, fontsize=7)
    fig.text(.02, .97, "openTPU on the Tang Nano 20K: the placed and routed GW2AR-18",
             color="#e6edf3", fontsize=11)
    plt.subplots_adjust(left=.01, right=.99, top=.95, bottom=.1)
    fig.savefig(path, facecolor=fig.get_facecolor())
    print(path)


if __name__ == "__main__":
    main()
