import sys
sys.path.insert(0, '.')
import tools.tang.winshim  # noqa
import numpy as np
from opentpu import isa as I
from tools.tang.bisect_model import both
rng = np.random.default_rng(0)
img = rng.integers(0, 256, 44 << 20, dtype=np.uint8)
tm = np.zeros(8192, np.uint32)
for addr in (0x100000, 0x1000000, 0x2000000, 0x272cd80):
    bt, bd, a, b, out = both([I.ld(addr, 0x14c0, 32), I.halt()], [0] * 8, img, tm)
    print(hex(addr), bt.size, bd.size, out)
