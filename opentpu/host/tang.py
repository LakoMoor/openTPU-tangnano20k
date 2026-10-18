"""The Tang Nano 20K board (targets/tangnano20k.toml, docs/tangnano20k.md): its host link and its
Engine backend.

The board speaks a small binary protocol over the BL616's USB UART (2 Mbaud; the virtual board,
sim/tang/tb_board.cpp, over TCP): DRAM word reads and writes, register reads and writes, and raw
reads of the SD card (rtl/boards/tangnano20k/tang_host.sv). The model's DRAM image lives on the
card as a file (tools/tang/sdimage.py writes it): the host finds the file's blocks through the
card's file system (FAT32 or exFAT, read raw through the board), tells the board where it is, and
the board reads the image from the card on demand; every DRAM write lands in the board's SDRAM
(copy on write), so the card is never written.

    link = TangLink("COM5")              # or "tcp:127.0.0.1:5555" (the virtual board)
    link.reg_read(0x000)                 # 0x4F545055 "OTPU"
    img = find_image(link, "OTPU.IMG")   # (first block, bytes)
    eng = Engine(spec, W, cfg=target.config("tangnano20k"), backend=TangBackend.factory(link))
"""
from __future__ import annotations

import os
import socket
import struct
import time

import numpy as np

# registers (tang_host.sv)
R_ID, R_VERSION, R_CTRL, R_STATUS = 0x000, 0x004, 0x008, 0x00C
R_PROG_ADDR, R_PROG_N, R_CYCLES_LO, R_CYCLES_HI, R_ICOUNT = 0x010, 0x014, 0x018, 0x01C, 0x020
R_SCRATCH, R_CAPS, R_CORE_KHZ, R_BUILD_ID, R_ARG0 = 0x038, 0x040, 0x044, 0x048, 0x060
R_CFG_TMEM, R_CFG_IMEM, R_CFG_ACT, R_CFG_DRAM, R_CFG_PLATFORM, R_CFG_HASH = \
    0x084, 0x088, 0x08C, 0x090, 0x098, 0x09C
R_IMG_LBA, R_IMG_BYTES, R_MAP, R_MAP_STATUS, R_FAULT_ADDR, R_LINE_FILLS, R_SD, R_ECODE = \
    0x200, 0x204, 0x208, 0x20C, 0x210, 0x214, 0x218, 0x21C
CTRL_RUN, CTRL_CLEAR = 0x1, 0x4
ST_HALTED, ST_ERROR, ST_LOADING, ST_WR_IDLE, ST_MEM, ST_SD, ST_RUN, ST_WAIT_TO = \
    0x1, 0x2, 0x4, 0x8, 0x20, 0x40, 0x80, 0x100
ECODES = {1: "an instruction this build does not run (DSTEP, STREAM, GATHER)",
          2: "a VOP function this build does not run", 3: "a bad LOOP (empty, nested end, depth)",
          4: "a WAITW timed out", 5: "a bad program load (HALT CHAIN)", 6: "a bad MM operand",
          7: "a bad QACT / QST operand", 8: "a memory error", 9: "the pc ran past the program"}
ACK = 0xA5
MAX_WORDS = 1024                          # words per R command: the BL616 bridge drops bytes of
                                          # longer bursts (8 KiB pass)
W_WORDS = 64                              # words per W command: the board's receive FIFO


class TangError(RuntimeError):
    pass


class TangLink:
    """The byte link to the board: a serial port ("COM5", "/dev/ttyUSB1") or a TCP socket
    ("tcp:HOST:PORT", the virtual board)."""

    def __init__(self, port: str | None = None, baud: int = 2_000_000, timeout: float = 5.0):
        port = port or os.environ.get("TANG_PORT") or "tcp:127.0.0.1:5555"
        self.port, self.timeout = port, timeout
        if port.startswith("tcp:"):
            _, host, p = port.split(":")
            self.sock = socket.create_connection((host, int(p)), timeout=timeout)
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.ser = None
        else:
            import serial
            self.ser = serial.Serial(port, baud, timeout=timeout)
            self.sock = None
        self.resync()

    # ---- bytes
    def _send(self, b: bytes) -> None:
        if self.sock:
            self.sock.sendall(b)
        else:
            self.ser.write(b)

    def _recv(self, n: int) -> bytes:
        out = bytearray()
        t0 = time.monotonic()
        while len(out) < n:
            if self.sock:
                try:
                    k = self.sock.recv(n - len(out))
                except socket.timeout:
                    k = b""
            else:
                k = self.ser.read(n - len(out))
            if not k and time.monotonic() - t0 > self.timeout:
                raise TangError(f"the board did not answer ({len(out)} of {n} bytes)")
            out += k
        return bytes(out)

    def resync(self) -> None:
        """Get the parser to wait for an opcode: no-ops, a pause past its stall timeout, and
        whatever the board was still sending dropped."""
        self._send(bytes(16))
        time.sleep(0.01)
        if self.sock:
            self.sock.setblocking(False)
            try:
                while self.sock.recv(65536):
                    pass
            except (BlockingIOError, OSError):
                pass
            self.sock.setblocking(True)
            self.sock.settimeout(self.timeout)
        else:
            self.ser.reset_input_buffer()

    def close(self) -> None:
        (self.sock or self.ser).close()

    # ---- commands
    def reg_write(self, reg: int, val: int) -> None:
        self._send(struct.pack("<BHI", 0x77, reg, val & 0xFFFFFFFF))
        if self._recv(1)[0] != ACK:
            raise TangError("register write not acknowledged")

    def reg_read(self, reg: int) -> int:
        self._send(struct.pack("<BH", 0x72, reg))
        return struct.unpack("<I", self._recv(4))[0]

    def write_words(self, addr: int, words) -> None:
        w = np.ascontiguousarray(words, dtype="<u4")
        for i in range(0, len(w), W_WORDS):
            part = w[i:i + W_WORDS]
            self._send(struct.pack("<BIH", 0x57, addr + 4 * i, len(part)) + part.tobytes())
            if self._recv(1)[0] != ACK:
                raise TangError("DRAM write not acknowledged")

    def read_words(self, addr: int, n: int, raw: bool = False) -> np.ndarray:
        out = np.empty(n, "<u4")
        for i in range(0, n, MAX_WORDS):
            k = min(MAX_WORDS, n - i)
            self._send(struct.pack("<BIH", 0x53 if raw else 0x52, addr + 4 * i, k))
            out[i:i + k] = np.frombuffer(self._recv(4 * k), "<u4")
        return out

    # ---- bytes at any alignment (the edges' words read, merged and written back)
    def write(self, addr: int, data) -> None:
        b = np.ascontiguousarray(data).view(np.uint8).reshape(-1)
        if b.size == 0:
            return
        a0, a1 = addr & ~3, (addr + b.size + 3) & ~3
        buf = np.empty(a1 - a0, np.uint8)
        if a0 != addr:
            buf[:4] = self.read_words(a0, 1).view(np.uint8)
        if a1 != addr + b.size:
            buf[-4:] = self.read_words(a1 - 4, 1).view(np.uint8)
        buf[addr - a0:addr - a0 + b.size] = b
        self.write_words(a0, buf.view("<u4"))

    def read(self, addr: int, n: int) -> np.ndarray:
        a0, a1 = addr & ~3, (addr + n + 3) & ~3
        w = self.read_words(a0, (a1 - a0) // 4)
        return w.view(np.uint8)[addr - a0:addr - a0 + n].copy()

    def read_card(self, block: int, nblocks: int = 1) -> bytes:
        """Raw card blocks (the first 4 GiB of the card)."""
        return self.read_words(block * 512, nblocks * 128, raw=True).tobytes()

    # ---- the board
    def info(self) -> dict:
        r = self.reg_read
        if r(R_ID) != 0x4F545055:
            raise TangError(f"not an openTPU board (ID {r(R_ID):#x})")
        sd = r(R_SD)
        return {"version": r(R_VERSION), "caps": r(R_CAPS), "core_khz": r(R_CORE_KHZ),
                "build": r(R_BUILD_ID), "platform": r(R_CFG_PLATFORM), "hash": r(R_CFG_HASH),
                "tmem": r(R_CFG_TMEM), "imem": r(R_CFG_IMEM), "act": r(R_CFG_ACT),
                "sdram_ready": bool(sd & 1), "sd_ready": bool(sd & 2), "sd_fail": bool(sd & 4),
                "sdhc": bool(sd & 8), "sd_state": sd >> 24}

    def wait_ready(self, timeout: float = 10.0, card: bool = True) -> dict:
        t0 = time.monotonic()
        while True:
            i = self.info()
            st = self.reg_read(R_STATUS)
            if i["sdram_ready"] and st & ST_MEM and (i["sd_ready"] or not card):
                return i
            if card and i["sd_fail"]:
                raise TangError("the SD card did not initialize (no card, or not an SD card)")
            if time.monotonic() - t0 > timeout:
                raise TangError(f"the board is not ready: {i}, STATUS {st:#x}")
            time.sleep(0.05)

    def set_image(self, lba: int, nbytes: int) -> None:
        """Point the board at the image (its first block, its size) and start from a clean
        address space (the page table and the line cache cleared, no COW page)."""
        self.reg_write(R_IMG_LBA, lba)
        self.reg_write(R_IMG_BYTES, nbytes)
        self.reg_write(R_MAP, 1)
        t0 = time.monotonic()
        while self.reg_read(R_MAP) & 1:
            if time.monotonic() - t0 > 5:
                raise TangError("the board's map reset did not finish")
            time.sleep(0.01)

    def run(self, prog_addr: int, n: int, args=(), timeout: float = 3600.0) -> dict:
        """Start the program at prog_addr (n instructions) with its arguments; wait for it."""
        self.start(prog_addr, n, args)
        return self.wait(timeout)

    def start(self, prog_addr: int, n: int, args=()) -> None:
        for k in range(8):
            v = int(args[k]) if k < len(args) else 0
            self.reg_write(R_ARG0 + 4 * k, v)
        self.reg_write(R_PROG_ADDR, prog_addr)
        self.reg_write(R_PROG_N, n)
        self.reg_write(R_CTRL, CTRL_CLEAR)
        self.reg_write(R_CTRL, CTRL_RUN)
        st = self.reg_read(R_STATUS)
        if not st & ST_RUN:
            raise TangError(f"the board did not start the run (STATUS {st:#x})")

    def halted(self) -> bool:
        return bool(self.reg_read(R_STATUS) & ST_HALTED)

    def wait(self, timeout: float = 3600.0) -> dict:
        t0 = time.monotonic()
        while True:
            st = self.reg_read(R_STATUS)
            if st & ST_HALTED:
                break
            if time.monotonic() - t0 > timeout:
                self.reg_write(R_CTRL, 0)
                raise TangError("the run did not halt")
            time.sleep(0.002)
        cyc = self.reg_read(R_CYCLES_LO) | self.reg_read(R_CYCLES_HI) << 32
        ic = self.reg_read(R_ICOUNT)
        self.reg_write(R_CTRL, 0)
        ms = self.reg_read(R_MAP_STATUS)
        if ms >> 31:
            raise TangError(f"the board's memory faulted at {self.reg_read(R_FAULT_ADDR):#x} "
                            f"({ms & 0xFFFF} COW pages used): out of SDRAM, or an address past "
                            "512 MiB")
        if st & ST_ERROR:
            e = self.reg_read(R_ECODE)
            raise TangError(f"the program stopped: {ECODES.get(e, e)}")
        return {"cycles": cyc, "instructions": ic, "status": st,
                "seconds": cyc / (self.reg_read(R_CORE_KHZ) * 1e3)}


# ------------------------------------------------------------------------------ the card's file
def _u(b, o, n):
    return int.from_bytes(b[o:o + n], "little")


def find_image(link: TangLink, name: str = "OTPU.IMG") -> tuple[int, int]:
    """(first block, bytes) of the file `name` in the card's first partition (FAT16, FAT32 or
    exFAT, the root directory), which must be contiguous: the board reads it by block number."""
    mbr = link.read_card(0)
    part = 0
    if (mbr[510:512] == b"\x55\xaa" and mbr[3:11] != b"EXFAT   " and mbr[82:87] != b"FAT32"
            and mbr[54:59] != b"FAT16"):
        part = _u(mbr, 446 + 8, 4)                     # partition 1's first block
    bs = link.read_card(part)
    want = name.upper()
    if bs[3:11] == b"EXFAT   ":
        return _exfat(link, part, bs, want)
    if bs[82:87] == b"FAT32":
        return _fat(link, part, bs, want, 32)
    if bs[54:59] == b"FAT16":
        return _fat(link, part, bs, want, 16)
    raise TangError("the card's first partition is not FAT16, FAT32 or exFAT")


def _fat(link, part, bs, want, bits):
    bps, spc, rsv, nfat = _u(bs, 11, 2), bs[13], _u(bs, 14, 2), bs[16]
    if bps != 512:
        raise TangError(f"FAT{bits} with sectors of other than 512 bytes")
    fat0 = part + rsv
    if bits == 32:
        root = _u(bs, 44, 4)
        data0 = fat0 + nfat * _u(bs, 36, 4)
    else:                                              # FAT16: a fixed root directory
        root0 = fat0 + nfat * _u(bs, 22, 2)
        rootn = (_u(bs, 17, 2) * 32 + 511) // 512
        data0 = root0 + rootn
    eb, end = (4, 0x0FFFFFF8) if bits == 32 else (2, 0xFFF8)

    def chain(c):
        out = []
        while 2 <= c < end:
            out.append(c)
            sec = link.read_card(fat0 + c * eb // 512)
            c = _u(sec, c * eb % 512, eb) & 0x0FFFFFFF
        return out

    def blk_of(c):
        return data0 + (c - 2) * spc
    dirs = ([link.read_card(blk_of(c), spc) for c in chain(root)] if bits == 32
            else [link.read_card(root0, rootn)])
    lfn = ""
    for d in dirs:
        for o in range(0, len(d), 32):
            e = d[o:o + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = ""
                continue
            if e[11] == 0x0F:                          # a long-name piece
                part_ = (e[1:11] + e[14:26] + e[28:32]).decode("utf-16-le", "ignore")
                lfn = part_.split("\x00")[0] + lfn
                continue
            short = (e[0:8].decode("ascii", "ignore").strip() + "." +
                     e[8:11].decode("ascii", "ignore").strip()).rstrip(".")
            names = {short.upper(), lfn.upper()}
            lfn = ""
            if want in names and not e[11] & 0x10:
                first = _u(e, 26, 2) | (_u(e, 20, 2) << 16 if bits == 32 else 0)
                size = _u(e, 28, 4)
                ch = chain(first)
                if ch != list(range(first, first + len(ch))):
                    raise TangError(f"{want} is fragmented on the card: copy it to a freshly "
                                    "formatted card (the board reads it as one run of blocks)")
                return blk_of(first), size
    raise TangError(f"no {want} in the card's root directory")


def _exfat(link, part, bs, want):
    bps_sh, spc_sh = bs[108], bs[109]
    if bps_sh != 9:
        raise TangError("exFAT with sectors of other than 512 bytes")
    fat0, heap, root = part + _u(bs, 80, 4), part + _u(bs, 88, 4), _u(bs, 96, 4)
    spc = 1 << spc_sh

    def blk_of(c):
        return heap + (c - 2) * spc

    def chain(c):
        out = []
        while 2 <= c < 0xFFFFFFF7:
            out.append(c)
            sec = link.read_card(fat0 + c * 4 // 512)
            c = _u(sec, c * 4 % 512, 4)
        return out
    entries = b"".join(link.read_card(blk_of(c), spc) for c in chain(root))
    i = 0
    while i < len(entries):
        e = entries[i:i + 32]
        if e[0] == 0:
            break
        if e[0] == 0x85:                               # a file: then stream, then names
            n2 = e[1]
            st = entries[i + 32:i + 64]
            nlen = st[3]
            nm = b"".join(entries[i + 64 + 32 * k + 2:i + 64 + 32 * k + 32] for k in range(n2 - 1))
            fname = nm.decode("utf-16-le", "ignore")[:nlen].upper()
            if fname == want and not _u(e, 4, 2) & 0x10:
                first, size, flags = _u(st, 20, 4), _u(st, 24, 8), st[1]
                if not flags & 0x02:                   # NoFatChain clear: check the chain
                    ch = chain(first)
                    if ch != list(range(first, first + len(ch))):
                        raise TangError(f"{want} is fragmented on the card")
                return blk_of(first), size
            i += 32 * (n2 + 1)
            continue
        i += 32
    raise TangError(f"no {want} in the card's root directory")


# ------------------------------------------------------------------------------ the Engine backend
class TangBackend:
    """Engine backend on the Tang Nano 20K. The model image must be on the card (the board's
    DRAM is the card's image with the SDRAM's copies of the pages written since set_image):
    the backend checks samples of it against the image the Engine built, then runs each
    program from the area after the image."""

    args = True
    generates = True
    chains = True

    def __init__(self, cfg, images: list, link: TangLink | None = None,
                 image_name: str = "OTPU.IMG", verify: int = 64):
        self.cfg = cfg
        self.link = link or TangLink()
        self.link.wait_ready()
        info = self.link.info()
        from opentpu import target as T
        if info["hash"] != T.arch_hash(cfg):
            raise TangError(f"the bitstream's configuration (hash {info['hash']:08x}) is not "
                            f"this one's ({T.arch_hash(cfg):08x})")
        img = np.asarray(images[0], np.uint8)
        lba, size = find_image(self.link, image_name)
        if size < img.size:
            raise TangError(f"{image_name} on the card has {size} bytes, the model's image "
                            f"{img.size}: write the image for this model (tools/tang/sdimage.py)")
        self.link.set_image(lba, size)
        rng = np.random.default_rng(img.size)
        for a in sorted(rng.integers(0, img.size // 4, verify)):
            got = self.link.read_words(4 * int(a), 1)[0]
            want = int(img[4 * a:4 * a + 4].view("<u4")[0])
            if got != want:
                raise TangError(f"{image_name} on the card is not this model's image (word "
                                f"{4 * a:#x}: card {got:#x}, image {want:#x}): write it with "
                                "tools/tang/sdimage.py")
        self.image_bytes = img.size
        self.prog_at = -(-img.size // 4096) * 4096
        self.cycles = 0
        self.last = None

    @classmethod
    def factory(cls, link=None, **kw):
        return lambda cfg, images: cls(cfg, images, link=link, **kw)

    def write(self, s, addr, data):
        self.link.write(addr, data)

    def read(self, s, addr, nbytes):
        return self.link.read(addr, nbytes)

    def slot_words(self, prog):
        from opentpu import isa as I
        return np.asarray(I.assemble(prog), np.uint32)

    def _load(self, programs) -> int:
        from opentpu import isa as I
        words = np.asarray(I.assemble(programs[0]), np.uint32)
        self.link.write_words(self.prog_at, words)
        return len(programs[0])

    def run(self, programs, args=None) -> dict:
        st = self.link.run(self.prog_at, self._load(programs), args or ())
        self.cycles += st["cycles"]
        self.last = st
        return st

    def run_generate(self, programs, out: int, n: int, on_token=None, stop=None,
                     state: int | None = None):
        """The generate loop on the board: its tokens handed over as they land in out[] (fp32
        ids, OUT_MARK until written), polled while it runs; stop() true writes the state
        block's stop word (the board halts after the token in flight)."""
        from opentpu.llm import generate as G
        self.link.start(self.prog_at, self._load(programs))
        got, asked = [], False

        def take() -> int:
            if len(got) >= n:
                return 0
            w = self.link.read_words(out + 4 * len(got), min(16, n - len(got)))
            new = w[:int(np.argmax(w == G.OUT_MARK))] if (w == G.OUT_MARK).any() else w
            for x in new.view(np.float32):
                got.append(int(x))
                if on_token is not None:
                    on_token(int(x))
            return len(new)
        try:
            while not self.link.halted():
                if not take():
                    time.sleep(0.05)
                if stop is not None and not asked and state is not None and stop():
                    self.link.write(state + 4 * G.S_HALT, np.ones(1, np.float32))
                    asked = True
            st = self.link.wait()
        except BaseException:
            self.link.reg_write(R_CTRL, 0)
            raise
        while take():
            pass
        self.cycles += st["cycles"]
        self.last = st
        return st, got
