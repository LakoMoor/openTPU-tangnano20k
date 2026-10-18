#!/usr/bin/env bash
# Program the Tang Nano 20K: ./flash.sh [sram|flash] (sram: until power off; flash: boots with it).
# FS: the bitstream (default: build/tangnano20k/tang_top.fs, else the prebuilt one).
set -euo pipefail
cd "$(dirname "$0")/../.."
TOOLS=${TOOLS:-/e/tools/oss-cad-suite}
export PATH="$TOOLS/bin:$TOOLS/lib:$PATH"
FS=${FS:-build/tangnano20k/tang_top.fs}
[ -f "$FS" ] || FS=boards/tangnano20k/prebuilt/tang_top.fs   # no build of your own: the prebuilt one
case "${1:-sram}" in
  sram)  openFPGALoader -b tangnano20k "$FS" ;;
  flash) openFPGALoader -b tangnano20k -f --verify "$FS" ;;
  *) echo "usage: $0 sram|flash"; exit 1 ;;
esac
