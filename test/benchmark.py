"""Where xap spends its cycles, phase by phase.

The emulator has one cycle counter, so timing the phases by reading it at each
boundary would cost more than the phases do -- a line is a couple of hundred
cycles and a 32-bit read and accumulate is a good fraction of that. Instead the
assembler is built five times, each stopping after one more phase, and the
costs come out as the differences. Every build still opens the file, reads all
of it and walks every line, so what changes between two of them is one phase
and nothing else, with no instrumentation in the measured path at all.

The fixed cost -- opening and closing two files -- is measured on an empty
source and subtracted, so the per-byte figures are the assembler's own work.

One bias to know about. A build that stops early still has to skip the rest of
the line, and skipping is cheaper per character than assembling but not free.
So a phase that consumes text hands the line-framing stage less to skip, and
the difference between two builds is that phase's cost minus the skipping it
saved. Framing is therefore overstated and every later phase understated, by
roughly fifteen cycles per character consumed. The total is exact -- stage 4
is the real assembler -- and the ordering is not in doubt, but the split
between framing and the phases is approximate.

    make bench X16EMU=/path/to/x16emu X16ROM=/path/to/rom.bin
"""

import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))

from emu import Emulator, labels, petscii

ROOT = os.path.join(os.path.dirname(__file__), "..")
BENCH = os.path.join(ROOT, "build", "bench.bin")
BENCH_LABELS = os.path.join(ROOT, "build", "bench.labels")

MAKE = os.environ.get("MAKE", "make")
TASS = os.environ.get("TASS", "64tass")
X16EMU = os.environ.get("X16EMU", "")

ORIGIN = 0x1000

STAGES = [
    (0, "read the file, frame the lines"),
    (1, "+ mnemonic lookup"),
    (2, "+ operand and addressing mode"),
    (3, "+ width selection"),
    (4, "+ encode and emit"),
]

# A mix rather than one instruction repeated, so the profile is not the cost of
# whichever form happens to be cheapest. Roughly the shape of hand-written 6502:
# mostly loads, stores and branches, with the odd indirect.
#
# The length is carried alongside because a branch has to reach its target, and
# with no labels yet the only way to write one is an absolute address -- so the
# generator tracks the program counter and points each branch at the
# instruction after it.
SAMPLE = [
    ("    lda #$12", 2),
    ("    sta $34", 2),
    ("    ldx $5678", 3),
    ("    inx", 1),
    ("    cmp $34,x", 2),
    ("    bne ${target:04x}", 2),
    ("    lda ($20),y", 2),
    ("    jsr $c000", 3),
    ("    asl a", 1),
    ("    ldy #$00", 2),
    ("    sty $04,x", 2),
    ("    pha", 1),
    ("    and #%00001111", 2),
    ("    ora $12", 2),
    ("    plp", 1),
    ("    jmp ($fffc)", 3),
]


def corpus(lines, origin=0x1000):
    """A source of the given number of lines, cycling through the sample."""
    out = []
    pc = origin
    for i in range(lines):
        text, length = SAMPLE[i % len(SAMPLE)]
        pc += length
        out.append(text.format(target=pc) + "\n")

    return "".join(out)


def build(stage):
    """Builds bench.bin stopped after the given phase."""
    r = subprocess.run(
        [MAKE, "-s", "-B", "build/bench.bin", "PROFILE=%d" % stage,
         "TASS=" + TASS],
        cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("build of stage %d failed:\n%s" % (stage, r.stderr))

    with open(BENCH, "rb") as fh:
        return fh.read(), labels(BENCH_LABELS)


def measure(code, sym, source):
    """Assembles source on the emulator and returns the cycle count."""
    fsroot = tempfile.mkdtemp(prefix="xap_bench_")
    try:
        with open(os.path.join(fsroot, "SRC.ASM"), "w") as fh:
            fh.write(source)

        src = petscii("SRC.ASM")
        obj = petscii("OUT.BIN,P,W")

        with Emulator(fsroot) as e:
            e.load(sym["xapBenchLoad"], code)
            e.load(sym["xapBenchSrcName"], src)
            e.poke(sym["xapBenchSrcLen"], len(src))
            e.load(sym["xapBenchObjName"], obj)
            e.poke(sym["xapBenchObjLen"], len(obj))
            e.poke16(sym["xapBenchOrigin"], ORIGIN)
            e.run(sym["xapBenchEntry"])

            result = e.peek(sym["xapBenchResult"])
            cycles = e.peek32(sym["xapBenchCycles"])

        if result != 0:
            sys.exit("xap reported error $%02X" % result)

        return cycles
    finally:
        shutil.rmtree(fsroot, ignore_errors=True)


def main():
    if not X16EMU or not os.path.exists(X16EMU):
        sys.exit("set X16EMU to a built x16emu")

    lines = int(os.environ.get("BENCH_LINES", "4000"))
    source = corpus(lines)
    size = len(source)

    print("xap phase profile")
    print("  %d lines, %d bytes of source\n" % (lines, size))

    rows = []
    for stage, name in STAGES:
        code, sym = build(stage)
        overhead = measure(code, sym, "")        # opens and closes, no work
        total = measure(code, sym, source)
        rows.append((stage, name, total - overhead, overhead, total))

    print("  %-34s %10s %10s %8s %7s"
          % ("phase", "cycles", "of which", "cyc/byte", "share"))
    print("  %-34s %10s %10s %8s %7s"
          % ("", "cumulative", "this phase", "", ""))
    print("  " + "-" * 73)

    net = rows[-1][2]
    previous = 0
    for stage, name, cycles, overhead, total in rows:
        delta = cycles - previous
        print("  %-34s %10d %10d %8.1f %6.1f%%"
              % (name, cycles, delta, delta / size, 100.0 * delta / net))
        previous = cycles

    print("  " + "-" * 73)
    print("  %-34s %10d %10s %8.1f %6.1f%%"
          % ("total, assembling", net, "", net / size, 100.0))
    print("  %-34s %10d" % ("fixed cost, opening and closing", rows[-1][3]))
    print()
    print("  %.1f cycles/byte -- %.3fs for %d bytes on an 8MHz X16"
          % (net / size, net / 8e6, size))


if __name__ == "__main__":
    main()
