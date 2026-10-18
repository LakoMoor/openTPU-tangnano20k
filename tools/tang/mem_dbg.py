import subprocess, sys, time, pathlib, tempfile
sys.path.insert(0, '.')
import tools.tang.winshim  # noqa
import numpy as np
from opentpu.host.tang import TangLink, find_image
from tools.tang import fatimg
img = (np.arange(3 << 18, dtype=np.uint32) * 2654435761 & 0xFFFFFFFF).astype("<u4")   # 3 MiB
tmp = pathlib.Path(tempfile.mkdtemp())
(tmp / "card.img").write_bytes(fatimg.build({"OTPU.IMG": img.tobytes()}))
sim = subprocess.Popen([str(pathlib.Path("sim/tang/obj/Vtb_board.exe").resolve()), str(tmp / "card.img"), "5557"], stdout=subprocess.PIPE, text=True)
print(sim.stdout.readline().strip())
try:
    l = TangLink("tcp:127.0.0.1:5557", timeout=60)
    print(l.wait_ready(timeout=60))
    t = time.time(); lba, size = find_image(l); print("image at", lba, size, f"{time.time()-t:.1f}s")
    l.set_image(lba, size)
    for a in (0, 4, 0x10000, 0x2FFFFC):
        print(hex(a), hex(l.read_words(a, 1)[0]), hex(img[a // 4]))
    print("past end", hex(l.read_words(0x400000, 1)[0]))
    t = time.time(); l.write_words(0x1000, [0x11111111, 0x22222222]); print("write ok", f"{time.time()-t:.1f}s")
    print([hex(x) for x in l.read_words(0xFF8, 6)], hex(img[0xFF8 // 4]), hex(img[0x1008 // 4]))
    print("map status", hex(l.reg_read(0x20C)), "fills", l.reg_read(0x214))
    l.write_words(0x500000, [7, 8]); print("zero page", [hex(x) for x in l.read_words(0x4FFFF8, 6)])
finally:
    sim.kill()
