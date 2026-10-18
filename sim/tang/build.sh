#!/usr/bin/env bash
# The virtual Tang Nano 20K: sim/tang/obj/Vtb_board.exe (tb_board.cpp: the UART as a TCP socket)
set -euo pipefail
cd "$(dirname "$0")/../.."
source /e/tangTPU/env.sh
B=rtl/boards/tangnano20k
SRCS="rtl/vpu/otpu_fp.sv rtl/lite/lite_pkg.sv rtl/lite/lite_fma.sv rtl/lite/lite_comp.sv
      rtl/lite/lite_seq.sv rtl/lite/lite_dma.sv rtl/lite/lite_vpu.sv rtl/lite/lite_quant.sv
      rtl/lite/lite_mm.sv rtl/lite/lite_core.sv
      $B/tang_sdram.sv $B/tang_sd.sv $B/tang_mem.sv $B/tang_uart.sv $B/tang_host.sv
      sim/tang/sdram_model.sv sim/tang/sd_model.sv sim/tang/tb_board.sv"
HASH=$(python tools/tang/arch_hash.py tangnano20k)
verilator -GARCH_HASH=$((16#$HASH)) --cc --exe -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH \
  -Wno-MULTIDRIVEN --top-module tb_board -Mdir sim/tang/obj $SRCS sim/tang/tb_board.cpp \
  -LDFLAGS -lws2_32
cd sim/tang/obj && vmake -j8 -f Vtb_board.mk OPT_FAST="-O2" >/dev/null
ls -la Vtb_board.exe
