# xap

A 65C02 assembler for the Commander X16, written in 65C02 assembly.

The intent is an assembler that could live in the X16's ROM, syntax-compatible
with the [Assembler in ROM](https://github.com/PeteGollan/X16_Assembler_in_ROM)
project so that it can stand in for it.

## What works now

Instructions, and nothing else. There are no labels, no symbolic constants, no
directives and no macros — every operand is a literal whose value is known the
moment it is read. What it does do is encode **every one of the W65C02S's 212
opcodes**, checked byte for byte against 64tass on every test run.

```
$ make test
```

Single pass, and each source byte is read exactly once. With no forward
references there is nothing that could yet force a second look; the shape is
the point. The reader only moves forward, bytes are emitted as soon as the
instruction is understood, and nothing is buffered for a later pass to
revisit. When labels arrive they add a patch list, not a second read.

At the moment that is 1.1KB of code and 1.4KB of tables. A ROM bank is 16KB.

## Building

Two host tools, neither vendored:

```
sudo apt install 64tass      # builds xap, and is the test oracle
pip install py65             # runs xap's own code on the host
```

```
make          # build/xap.bin and build/bench.bin
make test     # build, then the whole suite
make isa      # regenerate src/isa.inc (only when the generator changes)
```

Both can be pointed elsewhere: `make test TASS=/path/to/64tass PYTHON=...`.

## Running it on the emulator

The host tests drive xap's inner loop against a block of memory. They are
fast and they cover encoding, but they never touch the KERNAL, so they say
nothing about the file reader and nothing about speed. For that there is a
second suite that runs the same code on the real machine.

Build [x16emu](https://github.com/X16Community/x16-emulator) and point the
tests at it — there is no packaged build to depend on, so the emulator tests
skip themselves when it is missing:

```
make test X16EMU=/path/to/x16emu X16ROM=/path/to/rom.bin
```

It works like this. The emulator's `-testbench` mode boots the machine
normally and then drops into a command loop on stdin that can set memory, run
code and read the result back; closing stdin exits it. `-fsroot` puts a host
directory on the emulated drive, so the harness writes the source there and
xap reads it through the KERNAL like any other file. `test/bench.asm` builds
xap together with a stub that hands it the two names and times it, as one
binary, so the harness reads every address it needs out of 64tass's label
file rather than being told twice.

Timing is the emulator's cycle counter at `$9FB8`: writing to it sets a base
and reading it latches the count since. It counts emulated cycles, so the
number is what the instruction stream would cost a real 8MHz X16 — it does
not move under `-warp` and does not care how busy the host is.

## Large files

The source is streamed, never loaded. A refill reads blocks into a 2K buffer
and then trims the buffer back to the last newline in it, carrying the partial
line after it to the front next time. So the window the assembler sees always
ends where a line does, a token can never straddle a refill, and the parser
can go on indexing off one pointer with Y.

Nothing is read twice and nothing is kept once it has been passed, so the
source can be any size at all — what stays in memory is the buffer, and the
buffer is a fixed size. Object code goes out the same way, through a 1K buffer
flushed when it fills.

Blocks come in through `MACPTR`, which fills memory directly at about half a
cycle a byte where `CHRIN` costs a hundred. Both `MACPTR` and `MCIOUT` are
allowed to refuse — the KERNAL documents devices without them — so there is a
byte-at-a-time path behind each.

## How it is put together

| | |
|---|---|
| `tools/gen_isa.py` | Derives the instruction table by asking 64tass to assemble every (mnemonic, mode) pair. py65 cross-checks 195 of the 212. |
| `src/isa.inc` | The generated table. Not edited by hand; `test_isa.py` re-derives it on every run and requires an exact match. |
| `src/lex.asm` | Mnemonics and numbers. |
| `src/mode.asm` | Which addressing mode the operand is. |
| `src/encode.asm` | Which opcode that means, and the bytes. |
| `test/harness.py` | Runs xap under py65 — no emulator needed at this stage. |

Two decisions worth knowing about:

**Mnemonics are looked up by a packed key.** Three letters, five bits each,
into one word. Finding one is a binary search over 70 sorted 16-bit values —
six compares — where the ROM assembler walks a linked list of variable-length
strings for the first token of every line.

**The parser reports the narrow mode and `xapSelect` settles the width.**
`lda $34` and `lda $1234` are the same shape; only the value tells them apart.
This also handles the case where the mnemonic simply has no narrow form —
`jmp ($34)` widens to absolute indirect because JMP has no zero page indirect.

## Where xap differs from 64tass on purpose

64tass is the oracle, but it is not always right about what the X16's CPU has:

- `nop #$12` and `nop $34` assemble to `$82` and `$44`, which are reserved,
  not instructions. `brk #$12` takes a signature byte. xap accepts none of the
  three; nor does the ROM assembler.
- `ldx a` is TAX to 64tass and `ldy a` is TAY. xap rejects both. The
  accumulator form belongs to `asl lsr rol ror inc dec` and nothing else.
- The Rockwell bit instructions are written `rmb3 $34` and `bbr3 $34,target`,
  which is the WDC datasheet's form and the one cc65 and py65 use. 64tass is
  the outlier, taking the bit as a first operand.

Those four families are absent from the ROM assembler entirely, and the X16
documentation recommends against using them because the 65C816 does not have
them. xap assembles them anyway: refusing would make it less capable than
every other assembler for the machine, and the recommendation is about what
programs should contain, not about what an assembler should understand.
