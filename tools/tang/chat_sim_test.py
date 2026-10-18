"""chat.py's path on the virtual board: a 1-layer random model with SmolLM2's tokenizer, its
image on a FAT32 card image, generate_card on the board (tokens picked on the device, streamed)
against the same Engine on the ISA simulator."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import tools.tang.winshim  # noqa: E402,F401
import torch  # noqa: E402
import transformers  # noqa: E402

from opentpu import target as T  # noqa: E402
from opentpu.host.tang import TANG_BLOCK, TangBackend, TangLink  # noqa: E402
from opentpu.llm import load_spec  # noqa: E402
from opentpu.llm.qwen3 import Engine, load_weights  # noqa: E402
from tools.tang import fatimg  # noqa: E402
from tools.tang.sdimage import model_image  # noqa: E402

TOK = pathlib.Path("E:/tangTPU/models/SmolLM2-135M-Instruct")


def main():
    torch.manual_seed(0)
    m = transformers.LlamaForCausalLM(transformers.LlamaConfig(
        hidden_size=576, num_hidden_layers=1, num_attention_heads=9, num_key_value_heads=3,
        head_dim=64, intermediate_size=1536, vocab_size=49152, rms_norm_eps=1e-5,
        rope_theta=1e5, tie_word_embeddings=True, max_position_embeddings=8192,
        bos_token_id=1, eos_token_id=2, pad_token_id=2)).float().eval()
    d = pathlib.Path(tempfile.mkdtemp())
    m.save_pretrained(d)
    for f in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.json",
              "merges.txt"):
        shutil.copy(TOK / f, d / f)
    img = model_image(d)
    card = d / "card.img"
    card.write_bytes(fatimg.build({"OTPU.IMG": img.tobytes() + bytes(-img.size % 65536)}))
    sim = subprocess.Popen([str(ROOT / "sim/tang/obj/Vtb_board.exe"), str(card), "5559"],
                           stdout=subprocess.PIPE, text=True)
    try:
        print(sim.stdout.readline().strip(), flush=True)
        link = TangLink("tcp:127.0.0.1:5559", timeout=900)
        link.wait_ready(timeout=600)
        spec, W = load_spec(d), load_weights(d)
        kw = dict(cap=256, cfg=T.config("tangnano20k"), resident=True, block=TANG_BLOCK)
        ref, dut = Engine(spec, W, **kw), Engine(spec, W, backend=TangBackend.factory(link), **kw)
        ids = [1, 5000, 77, 12]
        ref.prefill(ids[:-1])
        dut.prefill(ids[:-1])
        seen = []
        a = ref.generate_card(ids[-1], 4)
        b = dut.generate_card(ids[-1], 4, on_token=seen.append)
        print("isa  :", a, "\nboard:", b, "streamed", seen, flush=True)
        sys.exit(0 if a == b == seen else 1)
    finally:
        sim.kill()
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    main()
