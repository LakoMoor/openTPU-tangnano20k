"""Print a target's arch_hash as 8 hex digits (the bitstream's CFG_HASH): arch_hash.py [NAME]"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import tools.tang.winshim  # noqa: E402,F401
from opentpu import target as T  # noqa: E402

print(f"{T.arch_hash(T.config(sys.argv[1] if len(sys.argv) > 1 else 'tangnano20k')):08x}")
