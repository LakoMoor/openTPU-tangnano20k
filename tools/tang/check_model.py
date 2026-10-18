"""A model on the Tang Nano 20K's configuration, on the ISA simulator, against Hugging Face:
greedy tokens for a chat prompt (what the board will produce, bit for bit).

    python tools/tang/check_model.py MODEL_DIR [--wformat int8] [--head-format int8] [--n 24]
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--head-format", default=None)
    ap.add_argument("--n", type=int, default=24)
    ap.add_argument("--prompt", default="What is the capital of France?")
    a = ap.parse_args()
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from opentpu import target as T
    from opentpu.llm import load_spec
    from opentpu.llm.qwen3 import Engine, load_weights
    tok = AutoTokenizer.from_pretrained(a.model)
    ids = tok(tok.apply_chat_template([{"role": "user", "content": a.prompt}], add_generation_prompt=True,
                                     tokenize=False), add_special_tokens=False)["input_ids"]
    hf = AutoModelForCausalLM.from_pretrained(a.model, torch_dtype=torch.float32)
    with torch.no_grad():
        g = hf.generate(torch.tensor([ids]), max_new_tokens=a.n, do_sample=False)[0, len(ids):]
    print("HF  :", repr(tok.decode(g)))
    kw = dict(cap=256, cfg=T.config("tangnano20k"), resident=True, wformat=a.wformat)
    if a.head_format:
        kw["head_format"] = a.head_format
    t0 = time.time()
    eng = Engine(load_spec(a.model), load_weights(a.model), **kw)
    out = eng.generate(ids, max_new=a.n)
    print("tang:", repr(tok.decode(out)), f"({time.time() - t0:.0f} s, image "
          f"{eng.image.nbytes / 2**20:.0f} MiB)")
    same = sum(1 for x, y in zip(out, g.tolist()) if x == y)
    print(f"first {min(len(out), len(g))} tokens: {same} the same")


if __name__ == "__main__":
    main()
