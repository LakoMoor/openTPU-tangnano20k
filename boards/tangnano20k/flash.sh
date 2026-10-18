#!/usr/bin/env bash
# Program the Tang Nano 20K: ./flash.sh [sram|flash] (sram: until power off; flash: boots with it)
set -euo pipefail
cd "$(dirname "$0")/../.."
TOOLS=${TOOLS:-/e/tools/oss-cad-suite}
export PATH="$TOOLS/bin:$TOOLS/lib:$PATH"
FS=build/tangnano20k/tang_top.fs
case "${1:-sram}" in
  sram)  openFPGALoader -b tangnano20k "$FS" ;;
  flash) openFPGALoader -b tangnano20k -f --verify "$FS" ;;
  *) echo "usage: $0 sram|flash"; exit 1 ;;
esac
