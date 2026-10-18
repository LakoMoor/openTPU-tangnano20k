"""A softmax in openTPU instructions on the Tang Nano 20K, against the ISA simulator (bit for bit)
and numpy (to fp32 rounding): the smallest end-to-end use of the board without a model.

    python examples/tangnano20k/softmax_isa.py --port COM6      # or tcp:127.0.0.1:5555 (sim/tang)

The program (docs/isa.md): LD the vector into TMEM, its maximum (VOP RMAX), 2^(x - max) (VOP
EXP2SUB, the max broadcast), the row sum (RSUM), its reciprocal (RECIP), the product (MUL), ST
the result. A TMEM scalar operand is B per row (B_ROW) with brs = 0 (B_SCALAR is the immediate).
softmax(x) = 2^(x' - max) / sum with x' = x * log2(e) (done on the host).
"""
import argparse
import dataclasses
import pathlib
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import tools.tang.winshim  # noqa: E402,F401  (Windows: fcntl)
from opentpu import isa as I  # noqa: E402
from opentpu import target as T  # noqa: E402
from opentpu.host.tang import TangLink  # noqa: E402
from opentpu.isasim import Machine  # noqa: E402

N = 64
X_AT, Y_AT, PROG_AT = 0x1000, 0x2000, 0x8000          # DRAM byte addresses
# TMEM word addresses
TX, TMAX, TE, TSUM, TINV, TY = 0, 100, 200, 300, 301, 400


def program():
    return [
        I.ld(X_AT, TX, N),                                                    # T[0..63] = x
        I.vop(I.V_RMAX, TMAX, TX, 0, 1, N, 1, N, 0),                          # max
        I.vop(I.V_EXP2SUB, TE, TX, TMAX, 1, N, N, N, 0, I.B_ROW),             # 2^(x - max)
        I.vop(I.V_RSUM, TSUM, TE, 0, 1, N, 1, N, 0),                          # sum
        I.vop(I.V_RECIP, TINV, TSUM, 0, 1, 1, 1, 1, 0),                       # 1 / sum
        I.vop(I.V_MUL, TY, TE, TINV, 1, N, N, N, 0, I.B_ROW),                 # e / sum
        I.st(Y_AT, TY, N),
        I.halt(),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None, help="COMx, /dev/ttyUSBx or tcp:HOST:PORT")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    x = np.random.default_rng(a.seed).standard_normal(N).astype(np.float32) * 3
    x2 = (x * np.float32(np.log2(np.e))).astype(np.float32)     # softmax in base 2
    prog = program()

    link = TangLink(a.port)
    link.wait_ready(card=False)
    link.set_image(0, 0)                          # no model: every page reads 0 until written
    link.write_words(X_AT, x2.view(np.uint32))
    link.write_words(PROG_AT, I.assemble(prog))
    st = link.run(PROG_AT, len(prog))
    board = link.read_words(Y_AT, N).view(np.float32)

    cfg = dataclasses.replace(T.config("tangnano20k"), DRAM_BYTES=1 << 16)
    dram = np.zeros(1 << 16, np.uint8)
    dram[X_AT:X_AT + 4 * N] = x2.view(np.uint8)
    sim = Machine(cfg, [prog], [dram]).run().slices[0].dram[Y_AT:Y_AT + 4 * N].view(np.float32)

    ref = np.exp(x - x.max()) / np.exp(x - x.max()).sum()
    print(f"board: {st['cycles']} cycles ({st['seconds'] * 1e6:.0f} us), {st['instructions']} instructions")
    print(f"board vs ISA simulator: {'bit-exact' if np.array_equal(board.view(np.uint32), sim.view(np.uint32)) else 'DIFFERENT'}")
    print(f"board vs numpy: max |error| {np.abs(board - ref).max():.2e}, sum {board.sum():.6f}")
    print("first values:", np.array2string(board[:6], precision=5))


if __name__ == "__main__":
    main()
