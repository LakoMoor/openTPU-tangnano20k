#!/usr/bin/env bash
# The Tang Nano 20K bitstream, open-source flow: yosys (+slang) -> nextpnr-himbaechel -> gowin_pack.
#   boards/tangnano20k/build.sh            -> build/tangnano20k/tang_top.fs
# Env: TOOLS (OSS CAD Suite), SEED (nextpnr), BAUD (the UART, default 2000000).
set -euo pipefail
cd "$(dirname "$0")/../.."
TOOLS=${TOOLS:-/e/tools/oss-cad-suite}
export PATH="$TOOLS/bin:$TOOLS/lib:$PATH"
OUT=build/tangnano20k
mkdir -p "$OUT"
B=rtl/boards/tangnano20k
SRCS="rtl/vpu/otpu_fp.sv rtl/lite/lite_pkg.sv rtl/lite/lite_fma.sv rtl/lite/lite_comp.sv
      rtl/lite/lite_seq.sv rtl/lite/lite_dma.sv rtl/lite/lite_vpu.sv rtl/lite/lite_quant.sv
      rtl/lite/lite_mm.sv rtl/lite/lite_core.sv
      $B/gowin_prims.v $B/tang_pll.v $B/tang_sdram.sv $B/tang_sd.sv $B/tang_mem.sv $B/tang_uart.sv $B/tang_host.sv $B/tang_top.sv"
SRCS=$(echo $SRCS)                     # one line: yosys splits commands at newlines
BUILD_ID=$(git rev-parse --short=8 HEAD 2>/dev/null || echo 0)
HASH=$(python tools/tang/arch_hash.py tangnano20k 2>/dev/null || echo 00000000)
echo "== yosys (build $BUILD_ID, arch hash $HASH)"
yosys -q -l "$OUT/yosys.log" -m slang -p "
  read_slang --ignore-assertions -D SYNTHESIS --top tang_top -G BUILD_ID=32'h$BUILD_ID -G ARCH_HASH=32'h$HASH -G BAUD=${BAUD:-2000000} $SRCS;
  hierarchy -top tang_top;
  synth_gowin -top tang_top -family gw2a -json $OUT/synth.json;
  tee -o $OUT/stat.txt stat"
echo "== nextpnr"
nextpnr-himbaechel -q -l "$OUT/nextpnr.log" --json "$OUT/synth.json" --write "$OUT/pnr.json" \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst=$B/tangnano20k.cst \
  --sdc $B/clocks.sdc --seed ${SEED:-1} ${NEXTPNR_EXTRA:-} --timing-allow-fail
echo "== gowin_pack"
gowin_pack -d GW2A-18C -o "$OUT/tang_top.fs" "$OUT/pnr.json"
ls -la "$OUT/tang_top.fs"
grep -E "Max frequency|utilisation|LUT4|DFF|BSRAM|ALU|MULT" "$OUT/nextpnr.log" | head -30 || true
