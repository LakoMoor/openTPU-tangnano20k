"""End to end on the virtual Tang Nano 20K (sim/tang: the whole board RTL with SDRAM and SD card
models, its UART on TCP): a small SmolLM2-shaped model's image in a FAT32 card image, the host's
TangBackend finding it, and every token's logits against the ISA simulator, bit for bit.

    python tools/tang/board_sim_test.py [--layers 1] [--vocab 2048] [--tokens 2] [--port 5555]
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402
import torch  # noqa: E402
import transformers  # noqa: E402

from opentpu import target as T  # noqa: E402
from opentpu.host.tang import TANG_BLOCK, TangBackend, TangLink  # noqa: E402
from opentpu.llm import load_spec  # noqa: E402
from opentpu.llm.qwen3 import Engine, load_weights  # noqa: E402
from tools.tang import fatimg  # noqa: E402
from tools.tang.sdimage import Capture  # noqa: E402

EXE = ROOT / "sim/tang/obj/Vtb_board.exe"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", type=int, default=1)
    ap.add_argument("--vocab", type=int, default=2048)
    ap.add_argument("--tokens", type=int, default=2)
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--sd", default=None, help="the card's bus: hs,POL,SAMP or 24 (TANG_SD)")
    a = ap.parse_args()
    cfg = T.config("tangnano20k")
    torch.manual_seed(0)
    m = transformers.LlamaForCausalLM(transformers.LlamaConfig(
        hidden_size=576, num_hidden_layers=a.layers, num_attention_heads=9, num_key_value_heads=3,
        head_dim=64, intermediate_size=1536, vocab_size=a.vocab, rms_norm_eps=1e-5,
        rope_theta=1e5, tie_word_embeddings=True, max_position_embeddings=8192,
        bos_token_id=1, eos_token_id=2, pad_token_id=0)).float().eval()
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d)
        m.save_pretrained(p)
        spec, W = load_spec(p), load_weights(p)
    kw = dict(cap=256, cfg=cfg, resident=True, wformat=a.wformat, block=TANG_BLOCK)
    img = Engine(spec, W, backend=Capture, **kw).backend.image
    pad = -img.size % 65536
    card = fatimg.build({"OTPU.IMG": img.tobytes() + bytes(pad)})
    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "card.img").write_bytes(card)
    print(f"image {img.size / 2**20:.1f} MiB, card {len(card) / 2**20:.1f} MiB", flush=True)
    sim = subprocess.Popen([str(EXE), str(tmp / "card.img"), str(a.port)],
                           stdout=subprocess.PIPE, text=True)
    try:
        print(sim.stdout.readline().strip(), flush=True)
        link = TangLink(f"tcp:127.0.0.1:{a.port}", timeout=600)
        print("board:", link.wait_ready(timeout=600), flush=True)
        print("sd:", link.sd_setup(a.sd), flush=True)
        ref = Engine(spec, W, **kw)
        dut = Engine(spec, W, backend=TangBackend.factory(link), **kw)
        ok = True
        for t in [1, 400, 77, 9][:a.tokens]:
            t0 = time.time()
            x, y = ref.step(t), dut.step(t)
            same = np.array_equal(x.view(np.uint32), y.view(np.uint32))
            ok &= same
            st = dut.backend.last
            print(f"token {t}: {'bit-exact' if same else 'DIFFERENT'} ({time.time() - t0:.0f}s wall, "
                  f"{st['cycles']} board cycles = {st['seconds']:.2f}s at 48 MHz, line fills "
                  f"{link.reg_read(0x214)}, COW pages {link.reg_read(0x20C) & 0xFFFF}, card reads restarted "
                  f"{link.reg_read(0x22C)})", flush=True)
        sys.exit(0 if ok else 1)
    finally:
        sim.kill()


if __name__ == "__main__":
    main()
