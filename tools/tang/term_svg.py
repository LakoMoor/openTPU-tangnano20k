"""Terminal-window SVGs of the board's logs (examples/tangnano20k/results) for the README and the
site: the command, then the log's lines (wrapped), in a dark terminal frame.

    python tools/tang/term_svg.py            # -> site/img/term_*.svg
"""
import html
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "examples/tangnano20k/results"
OUT = ROOT / "site/img"
COLS, LH, CW = 96, 18, 7.8          # columns, line height, char width (13px monospace)

SHOTS = [
    ("chat_stories42M", "python tools/tang/chat.py models/stories42M-pad --image STORY42.IMG --wformat int8 --raw "
                        "--sd hs,1,2,1 --prompt \"Once upon a time\" --max-new 48",
     lambda l: not l.startswith(("#", "board:", "sd:"))),
    ("chat_smollm2_135m", "python tools/tang/chat.py models/SmolLM2-135M-Instruct --image SMOL135.IMG --wformat fp4 "
                          "--head-format int8 --sd hs,1,2,1 --prompt \"What is the capital of France?\"",
     lambda l: not l.startswith(("#", "board:", "sd:"))),
    ("bringup", "python tools/tang/bringup.py --port COM6 --image STORY42.IMG --speed --sd hs,1,2,1",
     lambda l: not l.startswith("#")),
    ("softmax_isa", "python examples/tangnano20k/softmax_isa.py --port COM6", lambda l: True),
    ("sdtune_sdhc", "python tools/tang/sdtune.py --port COM6",
     lambda l: not l.startswith(("#", "24: ", "hs,"))),          # (not the stress read's lines)
]


def colour(line: str) -> str:
    if line.startswith("$ "):
        return "#7ee787"
    if "bit-exact" in line or "0 words wrong" in line or "passing" in line:
        return "#79c0ff"
    if line.startswith("["):
        return "#8b949e"
    return "#e6edf3"


def svg(cmd: str, lines: list[str]) -> str:
    rows = []
    for l in ["$ " + cmd] + lines:
        rows += textwrap.wrap(l, COLS, subsequent_indent="  ", break_on_hyphens=False) or [""]
    w, h = int(COLS * CW + 32), 44 + LH * len(rows) + 14
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
           f'<rect width="{w}" height="{h}" rx="10" fill="#0d1117" stroke="#30363d"/>',
           '<circle cx="18" cy="16" r="5" fill="#ff5f56"/><circle cx="36" cy="16" r="5" fill="#ffbd2e"/>'
           '<circle cx="54" cy="16" r="5" fill="#27c93f"/>',
           f'<text x="{w / 2}" y="20" fill="#8b949e" font-family="ui-monospace,Consolas,monospace" '
           'font-size="12" text-anchor="middle">tang nano 20k — openTPU</text>']
    for i, r in enumerate(rows):
        out.append(f'<text x="16" y="{44 + LH * i + 12}" fill="{colour(r)}" xml:space="preserve" '
                   f'font-family="ui-monospace,Consolas,monospace" font-size="13">{html.escape(r)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, cmd, keep in SHOTS:
        f = RES / f"{name}.txt"
        if not f.exists():
            continue
        lines = [l.rstrip() for l in f.read_text(encoding="utf-8", errors="ignore").splitlines()
                 if l.strip() and "Warning" not in l and keep(l)]
        if name == "chat_stories42M":           # (a raw prompt: the text goes on from it)
            lines = ["Once upon a time" + l if l.startswith(", there") else l for l in lines]
        (OUT / f"term_{name}.svg").write_text(svg(cmd, lines), encoding="utf-8")
        print(OUT / f"term_{name}.svg")


if __name__ == "__main__":
    main()
