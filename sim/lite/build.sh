#!/usr/bin/env bash
# Build the lite core's Verilator testbench: sim/lite/obj/Vlite_core.exe
set -euo pipefail
cd "$(dirname "$0")/../.."
source /e/tangTPU/env.sh
SRCS="rtl/vpu/otpu_fp.sv rtl/lite/lite_pkg.sv rtl/lite/lite_fma.sv rtl/lite/lite_comp.sv
      rtl/lite/lite_seq.sv rtl/lite/lite_dma.sv rtl/lite/lite_vpu.sv rtl/lite/lite_quant.sv
      rtl/lite/lite_mm.sv rtl/lite/lite_core.sv"
verilator --cc --exe -O3 -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
  --top-module lite_core -Mdir sim/lite/obj $SRCS sim/lite/tb_lite.cpp
cd sim/lite/obj && vmake -j8 -f Vlite_core.mk OPT_FAST="-O2" >/dev/null
ls -la Vlite_core.exe
