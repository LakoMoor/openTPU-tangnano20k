"""Windows shim: openTPU's host code imports fcntl (Linux file locks). On Windows the stand-in in
compat/ is put on sys.path (spawned workers inherit sys.path)."""
import sys
from pathlib import Path

if sys.platform == "win32":
    p = str(Path(__file__).resolve().parent / "compat")
    if p not in sys.path:
        sys.path.insert(0, p)

# temporary files (model checkpoints, DRAM images of the co-simulations) go to the build tree, not
# the system drive: TANG_TMP, else E:/tangTPU/build/tmp when it exists
import os
import tempfile

_tmp = os.environ.get("TANG_TMP") or ("E:/tangTPU/build/tmp" if Path("E:/tangTPU/build/tmp").is_dir() else None)
if _tmp:
    os.environ["TMP"] = os.environ["TEMP"] = os.environ["TMPDIR"] = _tmp
    tempfile.tempdir = _tmp
