import sys
sys.path.insert(0, '.')
import tools.tang.cosim as C
import numpy as np
from opentpu import isa as I
rng = np.random.default_rng(1)
dram = C.base_dram(rng)
for f in C.ELEM:
    for bm in range(4):
        r = C.check([I.vop(f, 4096, 0, 2048, 1, 4, 4, 4, 0, bm, imm=1.5)], dram, seed=0,
                    name=f"{I.VFUNCS[f]} bm{bm}")
        print(r)
