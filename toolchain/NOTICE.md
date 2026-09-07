# Committed toolchain

These are third-party build artefacts. None of it is xap's own code and none of
it is modified from upstream.

Two of the four are committed, so that most of the test loop works from a fresh
clone with nothing installed. The other two are fetched by
`tools/setup-toolchain.sh`, because this repository is public and they are not
ours to redistribute: 64tass is GPL-2.0, which would oblige us to offer its
source alongside the binary, and rom.bin is someone else's KERNAL build.
Running the script once gets both.

`tools/setup-toolchain.sh` is what produced each of these, from the pinned
version recorded there, and `make toolchain` re-runs it. The binaries are
Linux x86-64; on any other platform run that script to rebuild them.

| Path | What | Version | Upstream | Licence |
|------|------|---------|----------|---------|
| `bin/64tass` | *Fetched, not committed.* Cross assembler. Builds xap, and is the oracle its output is compared against. | 1.59.3120-2 (Ubuntu) | [64tass](https://sourceforge.net/projects/tass64/) | GPL-2.0-or-later |
| `bin/x16emu` | Commander X16 emulator. Runs the file I/O tests and produces every cycle count. | 77f2bab | [X16Community/x16-emulator](https://github.com/X16Community/x16-emulator) | BSD-2-Clause |
| `rom/rom.bin` | *Fetched, not committed.* X16 KERNAL ROM, r49 with the Assembler in ROM in bank 16. | r49_ti | [PeteGollan/X16_Assembler_in_ROM](https://github.com/PeteGollan/X16_Assembler_in_ROM) | see upstream |
| `pylib/py65` | 6502 simulator. Runs xap's own code on the host, so the encoding tests need no emulator. | 1.2.0 | [py65](https://github.com/mnaberez/py65) | BSD-3-Clause |

The two that are committed are BSD licensed, which asks that the copyright
notice and disclaimer travel with the binary. They are in `licenses/`.
