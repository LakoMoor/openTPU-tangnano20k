# openTPU on the Sipeed Tang Nano 20K

The Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7: 20,736 LUT4, 15,552 flip-flops, 46 block RAMs,
64 Mbit embedded SDRAM, a TF card slot, a BL616 USB-UART bridge) runs openTPU's ISA with real
language models. The weights stream from a file on the SD card. Target:
`targets/tangnano20k.toml`. Measured results: [examples/tangnano20k/results](../examples/tangnano20k/results);
how to run it: [examples/tangnano20k](../examples/tangnano20k/README.md).

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
- The units share TMEM, the multiply-add and the memory port as OR-ed buses: an idle unit
  drives zeros.

The results are the ISA simulator's **bit for bit**. Only the speed differs.

| | |
|:--|:--|
| arch | S 1, D 64, MCOLS 4 (= ACT_ROWS), ACT_BLOCKS 64, TMEM 8K words, IMEM 4096 words (512 instructions), DRAM 1 GiB |
| not in this build | PAIR / DUP, DSTEP, STREAM, GATHER, wait counts. The compiler falls back to VOPs. |
| core clock | 48 MHz (nextpnr, routed: 58.2 MHz) |
| resources | LUT4 17.2K / 20.7K (83%), BSRAM 39 / 46 (TMEM 16, IMEM 8, ACT RAM 8) |

## Memory: the card's image, the SDRAM as its cache and its writable copy

`rtl/boards/tangnano20k/tang_mem.sv`. The core and the host see a 1 GiB DRAM. That DRAM is the
model image file on the card plus the SDRAM:

- **Page table.** A half word per 4 KiB page, kept in SDRAM (128K words), with a 256-entry TLB.
- **Reads.** A page without its own copy reads the image. The 64 KiB line holding it comes
  from the card into one of 16 SDRAM lines (CMD18, 128 blocks, then CMD12). Past the image's
  end, a read returns 0.
- **Writes (copy on write).** The first write to a page copies the page from the image, or
  zeros, into one of 1,664 SDRAM pages and maps it. The card is never written.
- **Sequential reads.** An 8-word chunk buffer serves them.

The SDRAM controller (`tang_sdram.sv`) uses the board's 180-degree clock and CAS latency 2.

## The SD card

`tang_sd.sv`: native mode, 4-bit bus, reads only.

- **Initialization** at ~375 kHz: CMD0, CMD8, ACMD41 (SDSC and SDHC), CMD2, CMD3, CMD7,
  ACMD6 (4 bits), CMD16. Repeated about every second while it fails (a card inserted later),
  and on the host's request (register 0x220 bit 31: the tools do it at start, so a card
  swapped while the board runs is picked up).
- **Data clock** 24 MHz (clk / 2), or **48 MHz high speed** after CMD6 when the host asks.
  At 48 MHz the card clock is `clk` itself (or its inverse) muxed onto the pin, and the pins
  are sampled on either edge after 0-3 cycles: `tools/tang/sdtune.py` finds the settings that
  read the card right (`--sd hs,POL,SAMP,NEG`).
- **Every block's CRC16** (one per DAT line) is checked. A block that fails it, or a card that
  sends nothing for 2^22 card clocks (SDHC allows 100 ms), restarts the read at that block:
  CMD12, then CMD18 again (up to 4 times a block). The line cache takes a block's words only
  once its CRC held. A block still bad after that is counted (register 0x220, bits 31:16) and
  the host's `TangLink` raises an error at the end of the run: wrong weights are never silent.

On the 2 GB SDSC and the SDHC cards used here, high speed reads 10.6-10.9 MB/s against
4.5-8.5 MB/s at 24 MHz (the card's own latency per block bounds both). On the SDHC card, high
speed sends a bad block now and then (the CRC catches it; 3 restarts in the stories42M run).

## Host link

The UART runs at 2 Mbaud through the BL616 (`tang_host.sv`). The protocol is binary: word reads
and writes of DRAM, register reads and writes, and raw card reads (the host reads the FAT
through these). The board buffers 512 received bytes while a write waits for the card (a COW
copy takes milliseconds): the host writes at most 64 words a command. The BL616 drops bytes of
bursts longer than about 8 KiB: the host reads at most 1024 words a command.

The registers are openTPU's map: ID, CTRL, STATUS, PROG_ADDR / N, CYCLES, ICOUNT, CAPS,
ARG0..7 and CFG_*. The board adds its own:

| reg | |
|:--|:--|
| 0x200 / 0x204 | the image's first block, its size |
| 0x208 | map reset (write 1), busy (read) |
| 0x20C / 0x210 | COW pages used, fault flag / fault address |
| 0x214 | line fills |
| 0x218 | SD: state, last command, tries, SDHC, fail, ready, SDRAM ready |
| 0x21C | the core's error code |
| 0x220 | SD bus: samp (1:0), high speed (2), clock inverted (3), sample on the falling edge (4), divider (15:8), reinit (31); read: blocks lost (31:16), high speed on / CMD6 done / its result (7:2) |
| 0x224 / 0x228 | the card's last response to the command 0x228 selects, timeouts |
| 0x22C | reads restarted (stalls, CRC errors) |

On the host, `opentpu/host/tang.py` has:

- `TangLink`: the link (a serial port, or TCP to the virtual board), `sd_config` /
  `sd_setup` (the bus), `card_check` (lost blocks raise);
- `find_image`: finds the image file on FAT16, FAT32 or exFAT. The file must be contiguous.
- `TangBackend`: the Engine backend. It checks samples of the card's image against the
  Engine's, runs programs, and runs the generate loop on the board, streaming the tokens.

## Steps

```sh
# 1. bitstream (OSS CAD Suite: yosys + slang, nextpnr-himbaechel, gowin_pack), or the prebuilt
boards/tangnano20k/build.sh                 # -> build/tangnano20k/tang_top.fs (SEED=7: 58.2 MHz)
boards/tangnano20k/flash.sh sram            # or: flash (boots with it)

# 2. a model's image for the card (the same options as the chat)
hf download HuggingFaceTB/SmolLM2-135M-Instruct --local-dir models/SmolLM2-135M-Instruct
python tools/tang/sdimage.py models/SmolLM2-135M-Instruct --wformat fp4 --head-format int8 --out SMOL135.IMG
#    copy it to the root of a freshly formatted FAT16 / FAT32 / exFAT card, insert it
#    (several models: one image each, any name, chosen with --image)

# 3. checks, the card's bus, then the chat
python tools/tang/bringup.py --port COM6 --image SMOL135.IMG --speed
python tools/tang/sdtune.py --port COM6     # prints e.g. --sd hs,1,2,1
python tools/tang/chat.py models/SmolLM2-135M-Instruct --port COM6 --image SMOL135.IMG \
    --wformat fp4 --head-format int8 --sd hs,1,2,1
```

## Which models fit

The board runs what the compiler maps onto its configuration; the limits are on-chip memory:

- **TMEM, 8K words** (16 of the 46 block RAMs). A decode step keeps the residual, a layer's
  projections and the attention's score buffers in it. For this TMEM the compiler projects each
  KV head's queries just before its attention (`LAZY_Q_TMEM` in `opentpu/llm/qwen3.py`; the
  same MMs, the same results), and the Tang tools use 64-token attention blocks
  (`TANG_BLOCK`). Hidden sizes up to 960 fit. TinyLlama-1.1B (hidden 2048) and Qwen3-0.6B
  (2048-wide query rows) need about 16K words: they do not fit even at 12K.
- **IMEM, 512 instructions.** stories110M's decode step (12 KV heads, unrolled) is 583.
  Doubling IMEM takes 8 more block RAMs.
- **Shapes.** head_dim, hidden and FFN must be multiples of D = 64. An FFN that is not can be
  zero-padded (`tools/tang/pad_ffn.py`: the same function). A query group larger than MCOLS
  attends in parts; the FFN streams through ACT RAM in chunks (both checks relaxed in
  `Spec.check`).
- **Architectures**: those of `opentpu.llm` (Llama, SmolLM, Qwen3, LFM2, Gemma 4, ...).
  TinyStories-1M / 33M are GPT-Neo (LayerNorm, learned positions, biases): not supported.

| model | format | image | checked (ISA simulator vs Hugging Face) |
|:--|:--|--:|:--|
| stories42M (karpathy/llama2.c, TinyStories), FFN padded | int8 | 47 MiB | 32 / 32 greedy tokens |
| SmolLM2-135M-Instruct | fp4, int8 head | 100 MiB | "The capital of France is Paris." |
| SmolLM2-360M-Instruct | fp4, int8 head | 239 MiB | 8 / 8 tokens, "The capital of France is Paris." |

Every token streams the whole image from the card, so the speed is the image size over the
card's rate. Prompts prefill four tokens per pass of the weights.

## Verification

- `tools/tang/cosim.py`: random programs on the RTL (`sim/lite`, Verilator) against `isasim`,
  bit for bit. Covers LD / ST / loops / RLD, every VOP, the reductions, OUTER, QACT / QST and
  MM in all four weight formats with every flag.
- `tools/tang/model_cosim.py`: a SmolLM2-135M-shaped network (2 layers, the full 49K vocab)
  on the RTL with resident decode. The logits match bit for bit in int8, int4, fp4 and nvfp4.
- `tools/tang/board_sim_test.py`: the whole board (`sim/tang`: SDRAM and SD card models, the
  UART as TCP) with the host's `TangBackend`. The image is in a FAT32 card image, and the
  logits match bit for bit. The card model stalls every 5th read and flips a bit in every
  97th block: the board restarts the reads (417 times in the test) and stays bit-exact, in
  high speed too. `tools/tang/chat_sim_test.py` checks the on-board generate loop.
- `tools/tang/check_model.py`: a real model on this configuration in `isasim`, against
  Hugging Face's greedy tokens.
- On the board: `bringup.py`, `examples/tangnano20k/softmax_isa.py` (bit-exact against
  `isasim`) and the chats in [examples/tangnano20k/results](../examples/tangnano20k/results).

## If something does not come up

- **No answer on the UART.** Try `BAUD=1000000 boards/tangnano20k/build.sh`, and pass
  `--baud` to the host tools.
- **SD card not ready** (bring-up step 2; register 0x218 has the controller state, 0x224 / 0x228
  the card's last responses). Reinsert the card or rerun the tool (it re-initializes the card).
- **"the SD card did not send N blocks"**: the bus settings (`sdtune.py`), or drop `--sd` for
  the 24 MHz bus.
- **"not this model's image"**: the image was built with other options (`--wformat`,
  `--head-format`) or for another configuration (after a change of `targets/tangnano20k.toml`,
  rebuild the images).
- **SDRAM words wrong** (step 3). `tang_sdram.sv`'s `RD_CAPTURE` (2) is the read capture delay.
