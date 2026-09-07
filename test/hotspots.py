"""Exact per-routine cycle counts, by stepping xap under py65.

The phase profile in benchmark.py answers "which phase", and it does that
without instrumentation, but it cannot answer "which routine" and its
attribution is skewed: a build that stops early still skips the rest of the
line, so framing is charged for scanning that the finished assembler never
does.

This steps the processor one instruction at a time and charges each
instruction's cycles to the routine its address falls in. That is exact, it
needs no build variants, and it is cycle for cycle the same 65C02 the emulator
runs -- py65 counts the real cycle cost of every opcode.

What it leaves out is file I/O, because it drives the memory entry point. That
costs about half a cycle a byte through MACPTR, so the difference does not
change any decision.

    make hotspots
"""

import bisect
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from emu import labels
from py65.devices.mpu65c02 import MPU

ROOT = os.path.join(os.path.dirname(__file__), "..")
BINARY = os.path.join(ROOT, "build", "xap.bin")
LABELS = os.path.join(ROOT, "build", "xap.labels")

# Laid out so that nothing can run into anything else: the source below the
# object code, the object code below xap itself, and the return address above
# all three. An earlier layout put the output where the source still had lines
# to be read, so the assembler ate its own input and the profile was of
# whatever that produced.
CODE = 0xA000
OUTPUT = 0x4000      # the object image, as src/xap.asm places it
RETURN = 0xBF00
SOURCE = 0xC000
ZP = 0x22

CORPUS = os.path.join(ROOT, "build", "isa_real.asm")

# Stepping in Python runs about a hundred thousand instructions a second, so
# this takes a prefix of the benchmark corpus rather than all of it. The corpus
# cycles through the instruction set in turn, so any prefix of more than a few
# hundred lines holds every form in much the same proportion as the whole.
LINES = int(os.environ.get("HOTSPOT_LINES", "1000"))


def corpus(lines):
    path = sys.argv[1] if len(sys.argv) > 1 else CORPUS
    with open(path) as fh:
        return "".join(fh.readlines()[:lines])


def code_symbols(path, low, high):
    """Code labels sorted by address, as (address, name).

    A label starting with an underscore is a step inside a routine, so its
    cycles are rolled up into the last routine label before it -- otherwise
    the answer is a list of branch targets rather than a list of routines.
    """
    syms = [(a, n) for n, a in labels(path).items() if low <= a < high]
    syms.sort()

    rolled = []
    owner = None
    for addr, name in syms:
        if not name.startswith("_"):
            owner = name
        rolled.append((addr, owner or name))

    return rolled


def main():
    with open(BINARY, "rb") as fh:
        code = fh.read()

    syms = code_symbols(LABELS, CODE, CODE + len(code))
    addresses = [a for a, _ in syms]

    source = corpus(LINES)
    size = len(source)

    # One object byte per two or three of source, so this is generous; the
    # point is that it fails loudly rather than quietly assembling nonsense.
    if SOURCE + size + 1 > 0x10000:
        sys.exit("%d bytes of source does not fit above $%04X -- "
                 "lower HOTSPOT_LINES" % (size, SOURCE))

    mpu = MPU()
    for i, b in enumerate(code):
        mpu.memory[CODE + i] = b
    body = source.encode("ascii") + b"\0"
    for i, b in enumerate(body):
        mpu.memory[SOURCE + i] = b

    for addr, value in ((ZP + 0, SOURCE), (ZP + 2, OUTPUT), (ZP + 4, 0x1000)):
        mpu.memory[addr] = value & 0xFF
        mpu.memory[addr + 1] = value >> 8

    mpu.sp = 0xFF
    for b in (((RETURN - 1) >> 8) & 0xFF, (RETURN - 1) & 0xFF):
        mpu.memory[0x0100 + mpu.sp] = b
        mpu.sp -= 1

    mpu.pc = CODE
    cost = {}
    calls = {}
    seen = None
    while mpu.pc != RETURN:
        pc = mpu.pc
        before = mpu.processorCycles
        mpu.step()

        i = bisect.bisect_right(addresses, pc) - 1
        name = syms[i][1] if i >= 0 else "?"
        cost[name] = cost.get(name, 0) + (mpu.processorCycles - before)
        if name != seen:
            calls[name] = calls.get(name, 0) + 1
            seen = name

    total = mpu.processorCycles

    print("xap hotspots")
    print("  %d lines, %d bytes, %d cycles, %.1f cycles/byte\n"
          % (LINES, size, total, total / size))
    print("  %-22s %10s %8s %7s %10s %8s"
          % ("routine", "cycles", "cyc/byte", "share", "entries", "cyc/entry"))
    print("  " + "-" * 71)

    for name, cycles in sorted(cost.items(), key=lambda kv: -kv[1]):
        n = calls.get(name, 0)
        print("  %-22s %10d %8.1f %6.1f%% %10d %8.1f"
              % (name, cycles, cycles / size, 100.0 * cycles / total, n,
                 cycles / n if n else 0))

    print("  " + "-" * 71)
    print("  %-22s %10d %8.1f %6.1f%%"
          % ("total", total, total / size, 100.0))
    print("\n  %.1f cycles a line over %d lines"
          % (total / LINES, LINES))


if __name__ == "__main__":
    main()
