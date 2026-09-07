# Committed toolchain

These are third-party build artefacts, committed so that a clone of xap has a
working build and test loop with no network and nothing to install. None of it
is xap's own code and none of it is modified from upstream.

`tools/setup-toolchain.sh` is what produced each of these, from the pinned
version recorded there, and `make toolchain` re-runs it. The binaries are
Linux x86-64; on any other platform run that script to rebuild them.

| Path | What | Version | Upstream | Licence |
|------|------|---------|----------|---------|
| `bin/64tass` | Cross assembler. Builds xap, and is the oracle its output is compared against. | 1.59.3120-2 (Ubuntu) | [64tass](https://sourceforge.net/projects/tass64/) | GPL-2.0-or-later |
| `bin/x16emu` | Commander X16 emulator. Runs the file I/O tests and produces every cycle count. | 77f2bab | [X16Community/x16-emulator](https://github.com/X16Community/x16-emulator) | BSD-2-Clause |
| `rom/rom.bin` | X16 KERNAL ROM, r49 with the Assembler in ROM in bank 16. | r49_ti | [PeteGollan/X16_Assembler_in_ROM](https://github.com/PeteGollan/X16_Assembler_in_ROM) | see upstream |
| `pylib/py65` | 6502 simulator. Runs xap's own code on the host, so the encoding tests need no emulator. | 1.2.0 | [py65](https://github.com/mnaberez/py65) | BSD-3-Clause |

Two things to know before this repository is published.

`64tass` is GPL-2.0, so distributing the binary carries an obligation to offer
the corresponding source. The setup script names the exact Ubuntu package
version, which is where that source is, but a public release should either
say so prominently or drop the binary and install it instead.

`rom.bin` is a KERNAL build from the Assembler in ROM project, redistributed
here because it is both the machine xap runs on and the thing to measure xap
against later, on the same file and the same clock. Its licence is whatever
X16Community's ROM and that project carry; it is not ours to relicense.
