import subprocess, sys, time, pathlib, tempfile
sys.path.insert(0, '.')
import tools.tang.winshim  # noqa
from opentpu.host.tang import TangLink
from tools.tang import fatimg
tmp = pathlib.Path(tempfile.mkdtemp())
(tmp / "card.img").write_bytes(fatimg.build({"OTPU.IMG": bytes(range(256)) * 1024}))
sim = subprocess.Popen([str(pathlib.Path("sim/tang/obj/Vtb_board.exe").resolve()), str(tmp / "card.img"), "5556"], stdout=subprocess.PIPE, text=True)
print(sim.stdout.readline().strip())
try:
    l = TangLink("tcp:127.0.0.1:5556", timeout=60)
    for i in range(60):
        sd = l.reg_read(0x218)
        print(f"sd reg {sd:08x} state {sd >> 24} ready {sd >> 1 & 1} fail {sd >> 2 & 1}")
        if sd & 6: break
        time.sleep(1.0)
finally:
    sim.kill()
