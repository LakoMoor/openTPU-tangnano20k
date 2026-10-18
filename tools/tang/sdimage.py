"""Write a model's DRAM image for the Tang Nano 20K's SD card (docs/tangnano20k.md).

    python tools/tang/sdimage.py MODEL_DIR [--out OTPU.IMG] [--cap 256] [--wformat fp4]
                                 [--head-format int8]

Builds the image exactly as the Engine does for the board (targets/tangnano20k.toml), padded to
64 KiB. Copy the file to the root of a FAT16 / FAT32 / exFAT card (freshly formatted: the file must be
contiguous), as OTPU.IMG unless the chat is told another name (--image).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402


class Capture:
    """An Engine backend that only keeps the image it is given."""
    args = generates = chains = True
    last = None

    def __init__(self, cfg, images):
        self.cfg, self.image = cfg, np.asarray(images[0], np.uint8)

    def write(self, s, addr, data):
        raise RuntimeError("not a run")

    read = run = write


def model_image(model_dir, cap=256, wformat="int8", head_format=None, cfg=None):
    from opentpu import target as T
    from opentpu.llm import load_spec
    from opentpu.llm.qwen3 import Engine, load_weights
    cfg = cfg or T.config("tangnano20k")
    spec, W = load_spec(model_dir), load_weights(model_dir)
    from opentpu.host.tang import TANG_BLOCK
    kw = dict(cap=cap, cfg=cfg, resident=True, wformat=wformat, backend=Capture, block=TANG_BLOCK)
    if head_format:
        kw["head_format"] = head_format
    eng = Engine(spec, W, **kw)
    return eng.backend.image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--out", default="OTPU.IMG")
    ap.add_argument("--cap", type=int, default=256)
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--head-format", default=None)
    a = ap.parse_args()
    img = model_image(a.model, a.cap, a.wformat, a.head_format)
    pad = -img.size % 65536
    with open(a.out, "wb") as f:
        f.write(img.tobytes())
        f.write(bytes(pad))
    print(f"{a.out}: {(img.size + pad) / 2**20:.1f} MiB (image {img.size} bytes)")


if __name__ == "__main__":
    main()
