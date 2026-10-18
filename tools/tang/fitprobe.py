"""Probe which tiny-core configs a model shape compiles for (isasim, few layers)."""
import sys, time, pathlib, tempfile
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa
import numpy as np, torch, transformers
from opentpu.isasim import Config
from opentpu.llm import load_spec
from opentpu.llm.qwen3 import Engine, load_weights

def smol(layers=2):
    return transformers.LlamaForCausalLM(transformers.LlamaConfig(
        hidden_size=576, num_hidden_layers=layers, num_attention_heads=9, num_key_value_heads=3,
        head_dim=64, intermediate_size=1536, vocab_size=49152, rms_norm_eps=1e-5,
        rope_theta=1e5, tie_word_embeddings=True, max_position_embeddings=8192,
        bos_token_id=1, eos_token_id=2, pad_token_id=0))

def main():
    D, M, T, AB = (int(x) for x in sys.argv[1:5])
    torch.manual_seed(0)
    m = smol().float().eval()
    p = pathlib.Path(tempfile.mkdtemp())
    m.save_pretrained(p)
    __import__("atexit").register(__import__("shutil").rmtree, p, True)
    (p / "config.json").write_text((p / "config.json").read_text().replace('"LlamaForCausalLM"', '"LlamaForCausalLM"'))
    spec, W = load_spec(p), load_weights(p)
    cfg = Config(S=1, D=D, MCOLS=M, ACT_BLOCKS=AB, TMEM_WORDS=T, DRAM_BYTES=1 << 28,
                 IMEM_WORDS=int(__import__("os").environ.get("IMEM", 1 << 18)), LANES=1)
    toks = [1, 400, 5000, 77, 9]
    with torch.no_grad():
        hf = m(torch.tensor([toks])).logits[0].numpy()
    t = time.time()
    eng = Engine(spec, W, cap=256, cfg=cfg, resident=True)
    dev = np.array([eng.step(t_) for t_ in toks])
    cos = (dev * hf).sum(-1) / np.linalg.norm(dev, axis=-1) / np.linalg.norm(hf, axis=-1)
    print("OK", cfg, "cos", cos.min(), "resident", eng.resident, f"{time.time()-t:.1f}s")



def proglens():
    import sys
    D, M, T, AB = (int(x) for x in sys.argv[2:6])
    torch.manual_seed(0)
    m = smol(int(sys.argv[6]) if len(sys.argv) > 6 else 2).float().eval()
    p = pathlib.Path(tempfile.mkdtemp())
    m.save_pretrained(p)
    __import__("atexit").register(__import__("shutil").rmtree, p, True)
    spec, W = load_spec(p), load_weights(p)
    cfg = Config(S=1, D=D, MCOLS=M, ACT_BLOCKS=AB, TMEM_WORDS=T, DRAM_BYTES=1 << 28,
                 IMEM_WORDS=int(__import__("os").environ.get("IMEM", 1 << 18)), LANES=1)
    eng = Engine(spec, W, cap=256, cfg=cfg, resident=True)
    for t_ in [1, 400, 5000]:
        eng.step(t_)
    for b, (progs, ra) in eng._decodes.items():
        print("decode bucket", b, "instrs", [len(p) for p in progs])
    print("image MiB", eng.image.nbytes / 2**20 if hasattr(eng, "image") else "?")


if __name__ == "__main__":
    proglens() if sys.argv[1] == "lens" else main()
