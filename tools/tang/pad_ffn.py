"""A Llama checkpoint with its FFN padded with zeros to a multiple of D (64): the board's
configuration needs the FFN in whole blocks. The padded model computes the same function (the
extra gate / up rows give silu(0) * 0 = 0, the extra down columns add nothing).

    python tools/tang/pad_ffn.py models/tinyllama-42M models/stories42M-pad

(karpathy's llama2.c stories42M, as nickypro/tinyllama-42M: FFN 1376 -> 1408.)
"""
import argparse
import json
import shutil
from pathlib import Path

import torch
from safetensors.torch import load_file, save_file


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--multiple", type=int, default=64)
    a = ap.parse_args()
    src, dst = Path(a.src), Path(a.dst)
    dst.mkdir(parents=True, exist_ok=True)
    sd = load_file(src / "model.safetensors") if (src / "model.safetensors").exists() else \
        torch.load(src / "pytorch_model.bin", map_location="cpu", weights_only=True)
    c = json.loads((src / "config.json").read_text())
    F = c["intermediate_size"]
    P = -F % a.multiple
    out = {}
    for k, v in sd.items():
        v = v.clone()
        if k.endswith(("gate_proj.weight", "up_proj.weight")):      # [F, H]: zero rows
            v = torch.cat([v, v.new_zeros(P, v.shape[1])])
        elif k.endswith("down_proj.weight"):                         # [H, F]: zero columns
            v = torch.cat([v, v.new_zeros(v.shape[0], P)], 1)
        out[k] = v.contiguous()                                      # (tied tensors: copies)
    save_file(out, dst / "model.safetensors", metadata={"format": "pt"})
    c["intermediate_size"] = F + P
    (dst / "config.json").write_text(json.dumps(c, indent=2))
    for n in ("tokenizer.json", "tokenizer_config.json", "tokenizer.model",
              "special_tokens_map.json", "generation_config.json"):
        if (src / n).exists():
            shutil.copy(src / n, dst / n)
    print(f"{dst}: FFN {F} -> {F + P}")


if __name__ == "__main__":
    main()
