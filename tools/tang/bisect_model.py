"""Find the first instruction of a model's program at which the lite RTL and the ISA simulator
part: the program is cut (instruction k replaced by HALT) and both runs compared, bisecting k.

    python tools/tang/bisect_model.py [--layers 2] [--wformat int8]
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402
import torch  # noqa: E402
import transformers  # noqa: E402

from opentpu import isa as I  # noqa: E402
from opentpu.isasim import Machine  # noqa: E402
from opentpu.llm import load_spec  # noqa: E402
from opentpu.llm.qwen3 import Engine, load_weights  # noqa: E402
from tools.tang.lite_backend import EXE, LiteBackend  # noqa: E402
from tools.tang.model_cosim import CFG  # noqa: E402


def both(prog, args, img, tmem):
    n = img.size
    at = -(-n // CFG.D) * CFG.D
    words = np.asarray(I.assemble(prog), np.uint32)
    buf = np.zeros(max(CFG.DRAM_BYTES, at + words.nbytes), np.uint8)
    buf[:n] = img
    buf[at:at + words.nbytes] = words.view(np.uint8)
    m = Machine(CFG, [prog], [buf[:CFG.DRAM_BYTES].copy()], args=args)
    m.slices[0].tmem[:] = tmem
    m.run()
    s = m.slices[0]
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d)
        (p / "in.bin").write_bytes(buf.tobytes())
        (p / "t.bin").write_bytes(tmem.tobytes())
        a = [int(x) & 0xFFFFFFFF for x in args] + [0] * 8
        r = subprocess.run([str(EXE), str(p / "in.bin"), str(buf.size), str(at), str(len(prog)),
                            str(p)] + [str(x) for x in a[:8]] + ["+seed=1", f"+tmem={p / 't.bin'}"],
                           capture_output=True, text=True)
        tm = np.frombuffer((p / "tmem.bin").read_bytes(), np.uint32)
        dr = np.frombuffer((p / "dram.bin").read_bytes(), np.uint8)[:CFG.DRAM_BYTES]
    bt = np.nonzero(tm != s.tmem)[0]
    bd = np.nonzero(dr != s.dram)[0]
    return bt, bd, tm, s.tmem, r.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", type=int, default=2)
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--list", type=int, default=0)
    ap.add_argument("--try", default="")
    a = ap.parse_args()
    torch.manual_seed(0)
    m = transformers.LlamaForCausalLM(transformers.LlamaConfig(
        hidden_size=576, num_hidden_layers=a.layers, num_attention_heads=9, num_key_value_heads=3,
        head_dim=64, intermediate_size=1536, vocab_size=49152, rms_norm_eps=1e-5,
        rope_theta=1e5, tie_word_embeddings=True, max_position_embeddings=8192,
        bos_token_id=1, eos_token_id=2, pad_token_id=0)).float().eval()
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d)
        m.save_pretrained(p)
        spec, W = load_spec(p), load_weights(p)

    def factory(cfg, images):
        b = LiteBackend(cfg, images)
        b.keep_log = True
        return b
    dut = Engine(spec, W, cap=256, cfg=CFG, resident=True, wformat=a.wformat, backend=factory)
    try:
        dut.step(1)
    except Exception as e:                       # noqa: BLE001
        print("step:", e)
    progs, args, img, tmem = dut.backend.log[0]
    prog = list(progs[0])
    print(f"program: {len(prog)} instructions, args {args}")
    print("image bytes", hex(img.size), "word at 0x272cd80:",
          img[0x272cd80:0x272cd90].view(np.uint32) if img.size > 0x272cd90 else "past the end")
    if "--try" in sys.argv:
        for spec_ in sys.argv[sys.argv.index("--try") + 1].split(";"):
            idx = []
            for part in spec_.split(","):
                lo_, _, hi_ = part.partition("-")
                idx += list(range(int(lo_), int(hi_ or lo_) + 1))
            bt, bd, tm, st, out = both([prog[i] for i in idx] + [I.halt()], args, img, tmem)
            print(spec_, "TMEM", bt.size, "DRAM", bd.size, out, bt[:4])
        return
    if "--list" in sys.argv:
        for i, ins in enumerate(prog[:int(sys.argv[sys.argv.index("--list") + 1])]):
            print(f"  {i}: {ins}")
        return
    bt, bd, *_ = both(prog, args, img, tmem)
    print(f"whole program: {bt.size} TMEM words, {bd.size} DRAM bytes differ")
    lo, hi = 0, len(prog)                         # cut at lo: same; cut at hi: different
    while hi - lo > 1:
        k = (lo + hi) // 2
        cut = prog[:k] + [I.halt()]
        bt, bd, *_ = both(cut, args, img, tmem)
        same = not bt.size and not bd.size
        print(f"  cut {k}: {'same' if same else 'differ'}", flush=True)
        lo, hi = (k, hi) if same else (lo, k)
    cut = prog[:hi] + [I.halt()]
    bt, bd, tm, st, out = both(cut, args, img, tmem)
    print(f"first differing instruction: {hi - 1}: {prog[hi - 1]}")
    print("context:")
    for i in range(max(0, hi - 6), hi):
        print(f"  {i}: {prog[i]}")
    if bt.size:
        print("TMEM", bt[:10], [hex(x) for x in tm[bt[:5]]], [hex(x) for x in st[bt[:5]]])
    if bd.size:
        print("DRAM", [hex(x) for x in bd[:10]])


if __name__ == "__main__":
    main()
