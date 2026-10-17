"""Windows shim: openTPU's host code imports fcntl (Linux file locks). On Windows the stand-in in
compat/ is put on sys.path (spawned workers inherit sys.path)."""
import sys
from pathlib import Path

if sys.platform == "win32":
    p = str(Path(__file__).resolve().parent / "compat")
    if p not in sys.path:
        sys.path.insert(0, p)
