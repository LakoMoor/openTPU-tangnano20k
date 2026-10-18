"""A SmolLM2-135M-shaped model (2 layers, random weights) on the lite RTL against the ISA
simulator: every token's logits bit for bit, resident decode (RLD, run arguments).

    python tools/tang/model_cosim.py [--layers 2] [--tokens 3] [--wformat int8|fp4|int4|nvfp4]
"""
import argparse
import pathlib
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401
import numpy as np  # noqa: E402
import torch  # noqa: E402
import transformers  # noqa: E402

from opentpu.isasim import Config  # noqa: E402
from opentpu.llm import load_spec  # noqa: E402
from opentpu.llm.qwen3 import Engine, load_weights  # noqa: E402
from tools.tang.lite_backend import LiteBackend  # noqa: E402

CFG = Config(S=1, D=64, MCOLS=4, ACT_BLOCKS=64, TMEM_WORDS=8192, DRAM_BYTES=1 << 26,
             IMEM_WORDS=4096, LANES=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", type=int, default=2)
    ap.add_argument("--tokens", type=int, default=3)
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--vocab", type=int, default=49152)
    a = ap.parse_args()
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
    kw = dict(cap=256, cfg=CFG, resident=True, wformat=a.wformat)
    ref = Engine(spec, W, **kw)
    dut = Engine(spec, W, backend=LiteBackend, **kw)
    toks = [1, 400, 5000, 77, 9, 123][:a.tokens]
    ok = True
    for t in toks:
        t0 = time.time()
        x, y = ref.step(t), dut.step(t)
        same = np.array_equal(x.view(np.uint32), y.view(np.uint32))
        ok &= same
        print(f"token {t}: {'bit-exact' if same else 'DIFFERENT'} ({time.time() - t0:.0f}s, "
              f"{dut.backend.cycles} RTL cycles so far)", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
