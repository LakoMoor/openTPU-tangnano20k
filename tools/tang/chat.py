"""Chat with a model on the Tang Nano 20K (docs/tangnano20k.md).

    python tools/tang/chat.py MODEL_DIR --port COM5 [--prompt "..."] [--max-new 64]
           [--wformat int8|fp4] [--head-format int8] [--cap 256] [--image OTPU.IMG] [--raw]

The model's image must be on the board's SD card (tools/tang/sdimage.py with the same options).
The prompt is prefilled in runs of up to 4 tokens (every weight streams from the card once a
run), then the board generates greedily by itself (tokens picked on the device, read as they
land). Without --prompt: an interactive loop (the context continues; /reset starts over).
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
    ap.add_argument("--port", default=None, help="COMx, /dev/ttyUSBx or tcp:HOST:PORT (TANG_PORT)")
    ap.add_argument("--prompt", default=None)
    ap.add_argument("--max-new", type=int, default=64)
    ap.add_argument("--cap", type=int, default=256)
    ap.add_argument("--wformat", default="int8")
    ap.add_argument("--head-format", default=None)
    ap.add_argument("--image", default="OTPU.IMG")
    ap.add_argument("--raw", action="store_true", help="no chat template (a base model)")
    a = ap.parse_args()

    from transformers import AutoTokenizer
    from opentpu import target as T
    from opentpu.host.tang import TangBackend, TangLink
    from opentpu.llm import load_spec
    from opentpu.llm.qwen3 import Engine, load_weights
    tok = AutoTokenizer.from_pretrained(a.model)
    spec, W = load_spec(a.model), load_weights(a.model)
    link = TangLink(a.port)
    print("board:", link.wait_ready(), file=sys.stderr)
    kw = dict(cap=a.cap, cfg=T.config("tangnano20k"), resident=True, wformat=a.wformat)
    if a.head_format:
        kw["head_format"] = a.head_format
    t0 = time.time()
    eng = Engine(spec, W, backend=TangBackend.factory(link, image_name=a.image), **kw)
    print(f"ready ({time.time() - t0:.0f} s)", file=sys.stderr)
    history = []

    def turn(text):
        if a.raw:
            ids = tok(text)["input_ids"]
        else:
            history.append({"role": "user", "content": text})
            ids = tok(tok.apply_chat_template(history, add_generation_prompt=True, tokenize=False),
                      add_special_tokens=False)["input_ids"]
            ids = ids[len(turn.fed):] if ids[:len(turn.fed)] == turn.fed else ids
        t1 = time.time()
        logits = eng.prefill(ids[:-1]) if len(ids) > 1 else None
        t2 = time.time()
        out = []

        def show(t):
            out.append(t)
            sys.stdout.write(tok.decode([t]))
            sys.stdout.flush()
        eng.generate_card(ids[-1], a.max_new, on_token=show)
        t3 = time.time()
        turn.fed = turn.fed + ids + out
        if not a.raw:
            history.append({"role": "assistant", "content": tok.decode(out, skip_special_tokens=True)})
        print(f"\n[{len(ids)} prompt tokens {t2 - t1:.1f} s, {len(out)} tokens {t3 - t2:.1f} s = "
              f"{len(out) / max(t3 - t2, 1e-9):.2f} tok/s]", file=sys.stderr)
        del logits
    turn.fed = []

    if a.prompt is not None:
        turn(a.prompt)
        return
    while True:
        try:
            text = input("> ")
        except EOFError:
            break
        if text.strip() == "/reset":
            eng.reset()
            history.clear()
            turn.fed = []
            continue
        turn(text)


if __name__ == "__main__":
    main()
