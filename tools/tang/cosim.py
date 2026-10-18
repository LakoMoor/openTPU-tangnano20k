"""Co-simulation of the openTPU lite core (rtl/lite) against the ISA simulator, bit for bit.

    python tools/tang/cosim.py [--n 50] [--seed 1] [--kind vop|red|outer|quant|mm|ctl|all]

Each test is a random program over random TMEM / DRAM contents. It runs on opentpu.isasim and on
the Verilator build of lite_core (sim/lite/build.sh; random memory stalls and latency); the
final TMEM and DRAM must be equal. Programs the ISA simulator rejects (a VOP hazard, a bad MM
operand) are skipped and redrawn.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402

from opentpu import isa as I  # noqa: E402
from opentpu.isasim import Config, Machine, SimError  # noqa: E402

EXE = ROOT / "sim/lite/obj/Vlite_core.exe"
CFG = Config(S=1, D=64, MCOLS=4, ACT_BLOCKS=64, TMEM_WORDS=8192, DRAM_BYTES=1 << 22,
             IMEM_WORDS=4096, LANES=1)
TINIT = 0x200000          # the TMEM image in DRAM (loaded first by every program)
PROG = 0x300000


def rand_f32(rng, n, special=0.02, scale=4.0):
    v = (rng.standard_normal(n) * scale * np.exp(rng.uniform(-3, 3, n))).astype(np.float32)
    b = v.view(np.uint32).copy()
    m = rng.random(n) < special
    picks = np.array([0, 0x80000000, 0x7F800000, 0xFF800000, 0x00000001, 0x80400000,
                      0x7F7FFFFF, 0x00800000], np.uint32)
    b[m] = rng.choice(picks, m.sum())
    return b


def run_rtl(dram: np.ndarray, prog_n: int, args, seed: int):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d)
        (p / "in.bin").write_bytes(dram.tobytes())
        r = subprocess.run([str(EXE), str(p / "in.bin"), str(CFG.DRAM_BYTES), str(PROG),
                            str(prog_n), str(p)] + [str(a) for a in args] + [f"+seed={seed}"],
                           capture_output=True, text=True, timeout=600)
        line = [ln for ln in r.stdout.splitlines() if ln.startswith("HALT")]
        if not line:
            raise RuntimeError(f"RTL run failed: {r.stdout} {r.stderr}")
        _, cyc, icount, err, ecode = line[0].split()
        tm = np.frombuffer((p / "tmem.bin").read_bytes(), np.uint32).copy()
        dr = np.frombuffer((p / "dram.bin").read_bytes(), np.uint8).copy()
        return tm, dr, int(cyc), int(icount), int(err), int(ecode)


def check(prog, dram, args=(), seed=1, name=""):
    """Run prog (after the TMEM load) on both; returns None if isasim rejects it, else
    (ok, message)."""
    full = [I.ld(TINIT, 0, CFG.TMEM_WORDS)] + list(prog) + [I.halt()]
    words = I.assemble(full)
    img = dram.copy()
    img[PROG:PROG + words.nbytes] = words.view(np.uint8)
    try:
        m = Machine(CFG, [full], [img.copy()], args=list(args)).run()
    except SimError:
        return None
    s = m.slices[0]
    tm, dr, cyc, icount, err, ecode = run_rtl(img, len(full), args, seed)
    if err:
        return False, f"{name}: RTL error code {ecode}"
    msgs = []
    bad = np.nonzero(tm != s.tmem)[0]
    if bad.size:
        i = bad[0]
        msgs.append(f"TMEM {bad.size} words differ, first T[{i}] rtl {tm[i]:08x} sim {s.tmem[i]:08x}")
    badd = np.nonzero(dr != s.dram)[0]
    if badd.size:
        i = badd[0]
        msgs.append(f"DRAM {badd.size} bytes differ, first [{i:#x}] rtl {dr[i]:02x} sim {s.dram[i]:02x}")
    if icount != s.icount:
        msgs.append(f"icount rtl {icount} sim {s.icount}")
    return (not msgs), f"{name}: {cyc} cycles " + ("; ".join(msgs) if msgs else "ok")


# ---------------------------------------------------------------- generators
def base_dram(rng):
    dram = rng.integers(0, 256, CFG.DRAM_BYTES, dtype=np.uint8)
    t = rand_f32(rng, CFG.TMEM_WORDS)
    dram[TINIT:TINIT + 4 * CFG.TMEM_WORDS] = t.view(np.uint8)
    return dram


ELEM = [I.V_ADD, I.V_SUB, I.V_RSUB, I.V_MUL, I.V_MAX, I.V_MIN, I.V_COPY, I.V_EXP2, I.V_RECIP,
        I.V_RSQRT, I.V_ABS, I.V_FILL, I.V_EXP2SUB, I.V_LOG2]
RED = [I.V_RSUM, I.V_RMAX, I.V_RSSQ, I.V_RDOT]


def gen_vop(rng):
    prog = []
    for _ in range(rng.integers(1, 4)):
        f = int(rng.choice(ELEM))
        rows, cols = int(rng.integers(1, 5)), int(rng.integers(1, 80))
        a, b, d = 0, 2048, 4096 + int(rng.integers(0, 64))
        bm = int(rng.integers(0, 4))
        prog.append(I.vop(f, d, a + int(rng.integers(0, 64)), b + int(rng.integers(0, 64)), rows,
                          cols, cols + int(rng.integers(0, 8)), cols + int(rng.integers(0, 8)),
                          int(rng.integers(0, 90)), bm, imm=float(rng.standard_normal() * 3)))
    return prog


def gen_red(rng):
    prog = []
    for _ in range(rng.integers(1, 3)):
        f = int(rng.choice(RED + [I.V_ARGMAX]))
        rows, cols = int(rng.integers(1, 4)), int(rng.integers(1, 200))
        if f == I.V_ARGMAX:
            prog.append(I.argmax(6000, int(rng.integers(0, 64)), rows, cols, 2, cols,
                                 int(rng.integers(-100, 100))))
        else:
            prog.append(I.vop(f, 6000, int(rng.integers(0, 64)), 3000 + int(rng.integers(0, 64)),
                              rows, cols, 1, cols, cols, int(rng.integers(0, 4)),
                              imm=float(rng.standard_normal())))
    return prog


def gen_outer(rng):
    rows, cols = int(rng.integers(1, 5)), int(rng.integers(1, 100))
    dm = str(rng.choice(["scalar", "column", "one"]))
    dst = 4000
    c = int(rng.choice([dst, 1000]))            # the column vector may overlap dst
    return [I.outer(dst, 2000, 3000, c, rows, cols, cols, 1, dmode=dm)]


def gen_quant(rng):
    prog = []
    rows, kb = int(rng.integers(1, 5)), int(rng.integers(1, 4))
    n = kb * CFG.D
    row = bool(rng.random() < 0.3)
    cs = 7000 if rng.random() < 0.4 else None
    rs = 7900 if rng.random() < 0.4 else None
    prog.append(I.qact(0, rows, int(rng.integers(0, 60 - kb)), kb, n, row=row, cscale=cs,
                       rscale=rs))
    rows2, kb2 = int(rng.integers(1, 4)), int(rng.integers(1, 4))
    row2 = bool(rng.random() < 0.5)
    half = row2 and rng.random() < 0.4
    es = int(rng.choice([1, 1, 2, 3]))
    prog.append(I.qst(2000, 0x100000 + int(rng.integers(0, 64)), 0x180000, rows2, kb2,
                      kb2 * CFG.D, kb2 * CFG.D * es + int(rng.integers(0, 16)), es, row=row2,
                      half=half))
    return prog


def gen_mm(rng):
    """QACT rows then an MM over them (formats, flags), weights / scales in DRAM."""
    D = CFG.D
    M = int(rng.integers(1, 5))
    kb = int(rng.integers(1, 5))
    ab = int(rng.integers(0, 64 - kb))
    prog = [I.qact(0, M, ab, kb, kb * D, row=bool(rng.random() < 0.3))]
    wf = int(rng.integers(0, 4))
    unit = rng.random() < 0.2
    rsc = (not unit) and wf != I.WNV and rng.random() < 0.2
    acc = rng.random() < 0.3
    asc = unit and acc and rng.random() < 0.5
    rmax = rng.random() < 0.3
    N = int(rng.integers(1, 40))
    k0 = int(rng.integers(0, 4))
    bpb = D if wf == I.W8 else D // 2
    rs = -(-(kb * bpb) // D) * D + D * int(rng.integers(0, 2))
    srs = 16 * int(rng.integers(8, 20))
    ors = N + int(rng.integers(0, 4))
    out = 3000
    prog.append(I.mm(0x80000, 0x40000 if not asc else 7000, out, N, kb, rs, ors, M, ab, srs,
                     unit=unit, acc=acc, rmax=rmax, ascale=7000 if asc else None, wf=wf, k0=k0,
                     rsc=rsc))
    return prog, wf


def fix_mm_dram(dram, rng, wf):
    # NVFP4 scales must have the sign bit clear; dw offsets small enough to matter
    sc = dram[0x40000:0x40000 + 0x8000]
    if wf == I.WNV:
        sc &= 0x7F
    else:
        sc[:] = np.where(rng.random(sc.size) < 0.8, sc % 12, sc)
    # the Sw words: sane fp32 values at every 16-byte offset
    w = rand_f32(rng, 0x8000 // 4, special=0.0, scale=0.05)
    sw = dram[0x40000:0x48000].view(np.uint32)
    sw[::4] = w[::4]


def gen_ctl(rng):
    """Registers, loops, RLD, LD / ST, through register-relative addresses."""
    prog = [I.li(1, 100), I.li(2, 0x1000), I.addi(3, 1, 5),
            I.loop(3, int(rng.integers(0, 4)), rcount=0),
            I.vop(I.V_ADD, 5000, 0, 64, 1, 8, 8, 8, 8, ra=1, rb=1),
            I.addi(1, 1, 8),
            I.st(0x120000, 5000, 16, ra=2),
            I.rld(4, 10, raw=True), I.rld(5, 11), I.rld(6, 12, mul=7, rb=3),
            I.ld(0x120000, 6000, 16, ra=2),
            I.loop(3, 2), I.loop(1, 3), I.addi(7, 7, 1),
            I.vop(I.V_MUL, 7000, 0, 0, 1, 4, 4, 4, 4, ra=7)]
    return prog


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--kind", default="all")
    a = ap.parse_args()
    kinds = ["ctl", "vop", "red", "outer", "quant", "mm"] if a.kind == "all" else [a.kind]
    rng = np.random.default_rng(a.seed)
    fails = done = 0
    for i in range(a.n):
        k = kinds[i % len(kinds)]
        for _ in range(20):
            dram = base_dram(rng)
            if k == "mm":
                prog, wf = gen_mm(rng)
                fix_mm_dram(dram, rng, wf)
            else:
                prog = {"vop": gen_vop, "red": gen_red, "outer": gen_outer, "quant": gen_quant,
                        "ctl": gen_ctl}[k](rng)
            r = check(prog, dram, args=[int(x) for x in rng.integers(0, 1 << 20, 8)],
                      seed=i + 1, name=f"{k}#{i}")
            if r is not None:
                break
        else:
            print(f"{k}#{i}: no valid program drawn")
            continue
        ok, msg = r
        done += 1
        if not ok:
            fails += 1
            print("FAIL", msg)
            for ins in prog:
                print("   ", ins)
        else:
            print(msg)
    print(f"{done - fails}/{done} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
