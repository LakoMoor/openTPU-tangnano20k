# Prebuilt bitstream

`tang_top.fs`: the bitstream every result in `examples/tangnano20k/results` was measured with.

- source: this repository's RTL (`boards/tangnano20k/build.sh`, `SEED=7`), OSS CAD Suite
  (yosys + slang, nextpnr-himbaechel, gowin_pack)
- clock 48 MHz (nextpnr after routing: 58.16 MHz), LUT4 17,229 / 20,736, BSRAM 39 / 46
- UART 2 Mbaud; arch hash `fbf57956` (`python tools/tang/arch_hash.py tangnano20k`); the
  BUILD_ID register reads `24f03996` (the commit the build started from)

```sh
openFPGALoader -b tangnano20k tang_top.fs            # SRAM: until power off
openFPGALoader -b tangnano20k -f --verify tang_top.fs   # flash: boots with it
```
sha256: f1363d00a6fc922aa1a183a6a72708d64bc602afb602bbe60626ac79e6140599
