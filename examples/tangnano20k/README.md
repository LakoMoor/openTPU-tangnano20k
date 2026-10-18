# Tang Nano 20K examples

Everything here runs against the real board (a serial port: `COM6`, `/dev/ttyUSB1`) or the
virtual one (`tcp:127.0.0.1:5555`, see "Without a board"). The design is described in
[docs/tangnano20k.md](../../docs/tangnano20k.md); measured results are in
[results/](results/).

## 0. Setup

```sh
pip install -e .                    # opentpu (numpy, torch, transformers, pyserial)
# toolchain for building the bitstream yourself: OSS CAD Suite (yosys with slang,
# nextpnr-himbaechel, gowin_pack, openFPGALoader). A prebuilt bitstream is in
# boards/tangnano20k/prebuilt/.
```

On Windows, run the tools from Git Bash or PowerShell; `tools/tang/winshim.py` stands in for
`fcntl` and puts temporary files under `build/tmp` when it exists.

## 1. Load the bitstream

```sh
openFPGALoader -b tangnano20k boards/tangnano20k/prebuilt/tang_top.fs      # SRAM, until power off
# or, after boards/tangnano20k/build.sh:
boards/tangnano20k/flash.sh sram          # flash: boots with it
```

## 2. Without a model: the ISA on the board

```sh
python examples/tangnano20k/softmax_isa.py --port COM6
```

```
board: 8876 cycles (185 us), 8 instructions
board vs ISA simulator: bit-exact
board vs numpy: max |error| 5.96e-08, sum 1.000000
```

The program is eight openTPU instructions (LD, RMAX, EXP2SUB, RSUM, RECIP, MUL, ST, HALT)
written with `opentpu.isa`; the script runs it on the board through `TangLink` and on
`opentpu.isasim`, and compares the bits.

## 3. A model's image on the SD card

```sh
hf download HuggingFaceTB/SmolLM2-135M-Instruct --local-dir models/SmolLM2-135M-Instruct
python tools/tang/sdimage.py models/SmolLM2-135M-Instruct --wformat fp4 --head-format int8 --out SMOL135.IMG
```

Copy the `.IMG` files to the root of a freshly formatted card (FAT16, FAT32 or exFAT; the
board reads each file as one run of blocks, so it must not be fragmented). Several models fit
on one card; pick one with `--image`.

| model | image (fp4, int8 head) |
|:--|--:|
| SmolLM2-135M-Instruct | 100 MiB |
| SmolLM2-360M-Instruct | 239 MiB |

## 4. Bring-up checks

```sh
python tools/tang/bringup.py --port COM6 --image SMOL135.IMG --speed
python tools/tang/sdtune.py --port COM6         # optional: the card's 48 MHz high speed mode
```

`bringup.py` checks the link, the card and the image, writes and reads back the SDRAM through
the copy-on-write pages, measures the card, and runs a VOP program bit-exactly.
`sdtune.py` tries the high speed bus's clock phases and prints the `--sd` setting to use (or
says to keep the 24 MHz bus).

## 5. Chat

```sh
python tools/tang/chat.py models/SmolLM2-135M-Instruct --port COM6 --image SMOL135.IMG \
    --wformat fp4 --head-format int8 --prompt "What is the capital of France?" --max-new 12
```

The options must be the ones the image was built with (the host checks samples of the card's
image against the image it would build). Without `--prompt` it is an interactive chat.

## 6. Check a model without the board

```sh
python tools/tang/check_model.py models/SmolLM2-360M-Instruct --wformat fp4 --head-format int8
```

runs the model on the board's configuration in the ISA simulator (whose results the board
reproduces bit for bit) against Hugging Face's greedy tokens, and reports the image size.

## Without a board

```sh
bash sim/tang/build.sh                       # Verilator: the whole board RTL, SDRAM and SD models
python tools/tang/board_sim_test.py          # a small model through the virtual board, bit for bit
python examples/tangnano20k/softmax_isa.py --port tcp:127.0.0.1:5555   # with sim/tang/obj/Vtb_board.exe CARD.img 5555 running
```
