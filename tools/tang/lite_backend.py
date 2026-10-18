"""Engine backend that runs every program on the lite core's Verilator build (sim/lite): proves
the lite RTL runs the real networks bit for bit (tools/tang/model_cosim.py)."""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / "sim/lite/obj/Vlite_core.exe"


class LiteBackend:
    args = True
    generates = True
    chains = True

    def __init__(self, cfg, images: list, seed: int = 1):
        assert cfg.S == 1
        self.cfg, self.seed = cfg, seed
        self.drams = [np.asarray(im, np.uint8).copy() for im in images]
        self.cycles = 0
        self.tmem = np.zeros(cfg.TMEM_WORDS, np.uint32)     # persists across runs, as on the card
        self.log = []                                        # (programs, args, image, tmem) per run
        self.keep_log = False

    def write(self, s, addr, data):
        v = np.ascontiguousarray(data).view(np.uint8).reshape(-1)
        self.drams[s][addr:addr + v.size] = v

    def read(self, s, addr, nbytes):
        return self.drams[s][addr:addr + nbytes].copy()

    def slot_words(self, prog):
        from opentpu import isa as I
        return np.asarray(I.assemble(prog), np.uint32)

    def run(self, programs, args=None) -> dict:
        from opentpu import isa as I
        img = self.drams[0]
        n = img.size
        at = -(-n // self.cfg.D) * self.cfg.D          # as rtlsim: the program after the image
        words = np.asarray(I.assemble(programs[0]), np.uint32)
        buf = np.zeros(at + words.nbytes, np.uint8)
        buf[:n] = img
        buf[at:at + words.nbytes] = words.view(np.uint8)
        a = [int(x) & 0xFFFFFFFF for x in (args or [])] + [0] * 8
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "in.bin").write_bytes(buf.tobytes())
            (p / "tmem_in.bin").write_bytes(self.tmem.tobytes())
            if self.keep_log:
                self.log.append((programs, list(args or []), img.copy(), self.tmem.copy()))
            size = max(self.cfg.DRAM_BYTES, buf.size)
            r = subprocess.run([str(EXE), str(p / "in.bin"), str(size), str(at),
                                str(len(programs[0])), str(p)] + [str(x) for x in a[:8]] +
                               [f"+seed={self.seed}", f"+tmem={p / 'tmem_in.bin'}"],
                               capture_output=True, text=True)
            line = [ln for ln in r.stdout.splitlines() if ln.startswith("HALT")]
            if not line:
                raise RuntimeError(f"lite RTL failed: {r.stdout} {r.stderr}")
            _, cyc, icount, err, ecode = line[0].split()
            if int(err):
                raise RuntimeError(f"lite RTL stopped with error {ecode}: {r.stderr.strip()}")
            out = np.frombuffer((p / "dram.bin").read_bytes(), np.uint8)
            self.tmem = np.frombuffer((p / "tmem.bin").read_bytes(), np.uint32).copy()
        self.drams[0] = out[:n].copy()
        self.cycles += int(cyc)
        return {"cycles": int(cyc), "icount": int(icount)}
