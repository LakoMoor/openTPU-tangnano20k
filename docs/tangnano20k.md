# openTPU on the Sipeed Tang Nano 20K

The Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7: 20,736 LUT4, 15,552 flip-flops, 46 block RAMs,
64 Mbit embedded SDRAM, a TF card slot, a BL616 USB-UART bridge) runs openTPU's ISA with the
real models. The weights stream from a file on the SD card. Target: `targets/tangnano20k.toml`.

## Why a different core

The card's microarchitecture in its smallest configuration (D = 32, two MXU columns, four VPU
lanes) synthesizes to about 62K LUT, 61K flip-flops and 146 block RAMs for the GW2A. That is
five times this FPGA. `rtl/lite` is a new implementation of the same ISA:

- One instruction at a time, one element at a time. The ISA's machine model already says
  that every instruction completes before the next one starts.
- One shared fp32 multiply-add pipeline (`lite_fma`, built from `otpu_fp`'s staged functions)
  does every operation: add is `a*1 + c`, mul is `a*b + (-0)`. The composite functions
  (`exp2`, `recip`, `rsqrt`, `log2`) are the ISA's fixed sequences on it (`lite_comp`).
- MM is exact integer accumulation per group, four rows in parallel, with an fp32 epilogue.
- VOP row sums keep the ISA's 64 interleaved partials and its folding tree.
- QACT and QST make two passes over TMEM.

The results are the ISA simulator's **bit for bit**. Only the speed differs.

| | |
|:--|:--|
| arch | S 1, D 64, MCOLS 4 (= ACT_ROWS), ACT_BLOCKS 64, TMEM 8K words, IMEM 4096 words (512 instructions), DRAM 512 MiB |
| not in this build | PAIR / DUP, DSTEP, STREAM, GATHER, wait counts. The compiler falls back to VOPs. |
| core clock | 48 MHz (nextpnr: 57.4 MHz) |
| resources | LUT4 16.9K / 20.7K (81%), DFF 40%, BSRAM 38 / 46 |

## Memory: the card's image, the SDRAM as its cache and its writable copy

`rtl/boards/tangnano20k/tang_mem.sv`. The core and the host see a 512 MiB DRAM. That DRAM is
the model image file on the card plus the SDRAM:

- **Page table.** A half word per 4 KiB page, kept in SDRAM, with a 256-entry TLB.
- **Reads.** A page without its own copy reads the image. The 64 KiB line holding it comes
  from the card into one of 16 SDRAM lines (CMD18, 128 blocks, then CMD12). Past the image's
  end, a read returns 0.
- **Writes (copy on write).** The first write to a page copies the page from the image, or
  zeros, into one of 1,728 SDRAM pages and maps it. The card is never written.
- **Sequential reads.** An 8-word chunk buffer serves them.

The SD card runs in native 4-bit mode at 24 MHz (`tang_sd.sv`). The SDRAM controller
(`tang_sdram.sv`) uses the board's 180-degree clock and CAS latency 2, like the board's
Game Boy port.

## Host link

The UART runs at 2 Mbaud through the BL616 (`tang_host.sv`). The protocol is binary: word
reads and writes of DRAM, register reads and writes, and raw card reads (the host reads the
FAT through these).

The registers are openTPU's map: ID, CTRL, STATUS, PROG_ADDR / N, CYCLES, ICOUNT, CAPS,
ARG0..7 and CFG_*. The board adds its own at 0x200: image block and size, map reset,
COW / fault status, line fills, SD status and the error code.

On the host, `opentpu/host/tang.py` has:

- `TangLink`: the link (a serial port, or TCP to the virtual board);
- `find_image`: finds the image file on FAT32 or exFAT. The file must be contiguous.
- `TangBackend`: the Engine backend. It checks samples of the card's image against the
  Engine's, runs programs, and runs the generate loop on the board, streaming the tokens.

## Steps

```sh
# 1. bitstream (OSS CAD Suite: yosys + slang, nextpnr-himbaechel, gowin_pack)
boards/tangnano20k/build.sh                 # -> build/tangnano20k/tang_top.fs
boards/tangnano20k/flash.sh sram            # or: flash (boots with it)

# 2. the model's image for the card (the same options as the chat)
hf download HuggingFaceTB/SmolLM2-135M-Instruct --local-dir models/SmolLM2-135M-Instruct
python tools/tang/sdimage.py models/SmolLM2-135M-Instruct --wformat fp4 --head-format int8 --out OTPU.IMG
#    copy OTPU.IMG to the root of a freshly formatted FAT32 / exFAT card, insert it

# 3. checks, then the chat
python tools/tang/bringup.py --port COM5 --speed
python tools/tang/chat.py models/SmolLM2-135M-Instruct --port COM5 --wformat fp4 --head-format int8
```

SmolLM2-135M-Instruct is 100 MiB in fp4 with an int8 head, or 140 MiB in int8. Every token
streams the whole image from the card. At about 11 MB/s that is roughly 9 s a token in fp4.
Prompts prefill four tokens per pass of the weights.

## Verification

- `tools/tang/cosim.py`: random programs on the RTL (`sim/lite`, Verilator) against `isasim`,
  bit for bit. Covers LD / ST / loops / RLD, every VOP, the reductions, OUTER, QACT / QST and
  MM in all four weight formats with every flag.
- `tools/tang/model_cosim.py`: a SmolLM2-135M-shaped network (2 layers, the full 49K vocab)
  on the RTL with resident decode. The logits match bit for bit in int8, int4, fp4 and nvfp4.
- `tools/tang/board_sim_test.py`: the whole board (`sim/tang`: SDRAM and SD card models, the
  UART as TCP) with the host's `TangBackend`. The image is in a FAT32 card image, and the
  logits match bit for bit. `tools/tang/chat_sim_test.py` checks the on-board generate loop.
- `tools/tang/check_model.py`: the real SmolLM2-135M-Instruct on this configuration in
  `isasim`, against Hugging Face's greedy tokens.

## If something does not come up

- **No answer on the UART.** Try `BAUD=1000000 boards/tangnano20k/build.sh`, and pass
  `--baud` to the host tools.
- **SD card not ready** (bring-up step 2; register 0x218 has the controller state). The data
  is sampled where `tang_sd.sv` raises the card clock. Bad reads at 24 MHz point at that phase.
- **SDRAM words wrong** (step 3). `tang_sdram.sv`'s `RD_CAPTURE` (2) is the read capture
  delay.
