"""End to end on the emulator: xap reads a file and writes a file.

The host tests drive xap's inner loop against a block of memory, which is fast
and covers encoding but never touches the KERNAL. These run the same code on a
real X16 with real files, which is the only way to test the streaming reader,
the block reads and the object writer -- and the only place a cycle count means
anything.

Skipped unless $X16EMU points at a build of x16emu. There is no packaged one to
depend on; see the README.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import gen_isa as g
from emu import Emulator, labels, petscii

ROOT = os.path.join(os.path.dirname(__file__), "..")
BENCH = os.path.join(ROOT, "build", "bench.bin")
BENCH_LABELS = os.path.join(ROOT, "build", "bench.labels")

TASS = os.environ.get("TASS", "64tass")
X16EMU = os.environ.get("X16EMU", "")

ORIGIN = 0x1000


def a_program(instructions):
    """A source file of the given instructions, repeated to length."""
    return "".join(line + "\n" for line in instructions)


class TestOnHardware(unittest.TestCase):
    sym = None
    code = None

    @classmethod
    def setUpClass(cls):
        if not X16EMU or not os.path.exists(X16EMU):
            raise unittest.SkipTest("$X16EMU is not a built x16emu")
        if not os.path.exists(BENCH):
            raise unittest.SkipTest("build/bench.bin is missing -- run make")
        cls.sym = labels(BENCH_LABELS)
        with open(BENCH, "rb") as fh:
            cls.code = fh.read()

    def assemble(self, source, origin=ORIGIN):
        """Assembles source on the emulator. Returns (bytes, cycles)."""
        fsroot = tempfile.mkdtemp(prefix="xap_emu_")
        try:
            with open(os.path.join(fsroot, "SRC.ASM"), "w") as fh:
                fh.write(source)

            src = petscii("SRC.ASM")
            # CBM DOS needs the type and mode to create a file for writing.
            obj = petscii("OUT.BIN,P,W")
            sym = self.sym

            with Emulator(fsroot) as e:
                e.load(sym["xapBenchLoad"], self.code)
                e.load(sym["xapBenchSrcName"], src)
                e.poke(sym["xapBenchSrcLen"], len(src))
                e.load(sym["xapBenchObjName"], obj)
                e.poke(sym["xapBenchObjLen"], len(obj))
                e.poke16(sym["xapBenchOrigin"], origin)

                e.run(sym["xapBenchEntry"])

                result = e.peek(sym["xapBenchResult"])
                cycles = e.peek32(sym["xapBenchCycles"])

            self.assertEqual(result, 0,
                             "xap reported error $%02X" % result)

            out = os.path.join(fsroot, "OUT.BIN")
            self.assertTrue(os.path.exists(out),
                            "no object file was written")
            with open(out, "rb") as fh:
                return fh.read(), cycles
        finally:
            shutil.rmtree(fsroot, ignore_errors=True)

    @staticmethod
    def for_tass(source):
        """The same source in 64tass's spelling.

        64tass takes the bit number of the Rockwell instructions as a first
        operand where xap, cc65 and the WDC datasheet attach it to the
        mnemonic.
        """
        return re.sub(r"\b(rmb|smb|bbr|bbs)([0-7])\s+",
                      r"\1 \2,", source, flags=re.I)

    def tass(self, source, origin=ORIGIN):
        """The same source through 64tass, as raw bytes."""
        source = self.for_tass(source)
        d = tempfile.mkdtemp(prefix="xap_tass_")
        try:
            src = os.path.join(d, "s.asm")
            out = os.path.join(d, "s.bin")
            with open(src, "w") as fh:
                fh.write("* = $%04X\n" % origin + source)
            r = subprocess.run([TASS, "--mw65c02", "-q", "-b", "-o", out, src],
                               capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr.decode())
            with open(out, "rb") as fh:
                return fh.read()
        finally:
            shutil.rmtree(d, ignore_errors=True)

    # ---- correctness ---------------------------------------------------

    def test_assembles_a_file_to_a_file(self):
        source = a_program(["nop", "lda #$12", "lda $34", "lda $5678",
                            "jmp ($1234)", "bcc $1010", "rmb3 $34",
                            "bbr0 $34,$1020", "inc a", "stp"])
        got, _ = self.assemble(source)
        self.assertEqual(got, self.tass(source))

    def test_a_file_larger_than_the_buffer(self):
        """The reader refills, and a line never straddles a refill.

        The buffer is 2K, so this is many refills and the carried tail lands
        at a different offset each time.
        """
        source = a_program(["lda #$%02X" % (i & 0xFF) for i in range(3000)])
        self.assertGreater(len(source), 8 * 2048)
        got, _ = self.assemble(source)
        self.assertEqual(got, self.tass(source))

    def test_output_larger_than_the_object_buffer(self):
        """More than 1K of object code, so the writer flushes mid-assembly."""
        source = a_program(["lda $5678"] * 2000)      # 6000 bytes out
        got, _ = self.assemble(source)
        self.assertEqual(len(got), 6000)
        self.assertEqual(got, self.tass(source))

    def test_lines_of_awkward_lengths(self):
        """Padding shifts every line boundary against the refill boundary."""
        for pad in (0, 1, 7, 63):
            source = a_program([" " * pad + "lda #$aa" for _ in range(700)])
            got, _ = self.assemble(source)
            self.assertEqual(got, self.tass(source), "pad=%d" % pad)

    def test_a_corpus_of_every_instruction_through_a_file(self):
        """The benchmark corpus, assembled on the machine, against 64tass.

        The encoding tests cover all 212 forms one line at a time in memory.
        This runs them as one file through the KERNAL -- many refills, many
        object flushes -- which is where a streaming bug would show and an
        encoding test never would.
        """
        # The whole file, not a prefix of it. Cutting a corpus that has
        # labels leaves references to labels past the cut, and those are
        # holes that never close -- which is a test of the fixup heap's
        # size and nothing else.
        path = os.path.join(ROOT, "build", "isa_even.asm")
        if not os.path.exists(path):
            self.skipTest("build/isa_even.asm is missing -- run make")
        with open(path) as fh:
            source = fh.read()

        got, _ = self.assemble(source)
        self.assertEqual(got, self.tass(source))

    def test_the_degenerate_corpus(self):
        """Every label used before any is defined, then defined backwards.

        The most holes the fixup table can be asked to hold at once, and the
        longest walk back through them.
        """
        path = os.path.join(ROOT, "build", "isa_jump_degenerate.asm")
        if not os.path.exists(path):
            self.skipTest("build/isa_jump_degenerate.asm is missing")
        with open(path) as fh:
            source = fh.read()

        got, _ = self.assemble(source)
        self.assertEqual(got, self.tass(source))

    # ---- the image is banked -------------------------------------------
    #
    # The object goes into banked RAM, eight 8K banks seen through one
    # window at $A000. Everything above the addressing layer treats it as a
    # flat run of bytes, so the only places the seam shows are where a byte
    # lands either side of it -- and those are the cases here. They need the
    # real machine, because the seam is the machine.

    def test_an_object_larger_than_one_bank(self):
        """Straightforward, but it has to cross."""
        source = a_program(["    lda $1234"] * 3000)      # 9000 bytes
        got, _ = self.assemble(source)
        self.assertEqual(len(got), 9000)
        self.assertEqual(got, self.tass(source))

    def test_an_absolute_fixup_that_straddles_a_bank_boundary(self):
        """The two bytes of an address, either side of the seam.

        A fixup is filled in through the window, and the window shows one
        bank. So an absolute operand whose low byte is the last byte of a
        bank has its high byte in the next one, and the resolver has to go
        and find it rather than adding one to the address it already has.

        Once in 8192, which is exactly why it is placed rather than hoped
        for: the JMP is put so that its opcode is the last byte but two of
        the first bank.
        """
        # Three bytes a line, up to the byte before the boundary.
        pad = (0x2000 - 2) // 3
        self.assertEqual(pad * 3, 0x2000 - 2, "the padding has to land exactly")

        lines = ["    lda $1234"] * pad     # to offset $1FFE
        lines += ["    jmp fwd"]            # opcode $1FFE, low $1FFF, high $2000
        lines += ["    nop", "fwd:", "    nop"]
        source = a_program(lines)

        got, _ = self.assemble(source)
        want = self.tass(source)
        self.assertEqual(got, want)

        # And say plainly what was being tested, so a pass means what it
        # looks like: the JMP really is astride the boundary.
        self.assertEqual(got[0x1FFE], 0x4C)
        self.assertEqual(got[0x1FFF] | (got[0x2000] << 8), ORIGIN + 0x2002)

    def test_a_widening_that_shifts_across_a_bank_boundary(self):
        """The expensive case, made to cross the seam.

        A forward reference inside the zero page is emitted narrow on the
        chance it fits. When it turns out not to, the image shifts up a
        byte from the hole to the top -- and with more than 8K above the
        hole that walk runs off the bottom of one bank into the top of the
        one below, in both directions at once, since it reads at one
        address and writes at the next.
        """
        lines = ["    lda fwd"]             # guessed narrow: origin is zero
        lines += ["    lda $1234"] * 3000   # 9000 bytes above the hole
        lines += ["fwd:", "    nop"]
        source = a_program(lines)

        got, _ = self.assemble(source, origin=0)
        want = self.tass(source, origin=0)
        self.assertEqual(got, want)

        # It really did widen: three bytes, not two, and the target is
        # where the label ended up.
        self.assertEqual(got[0], 0xAD)
        self.assertEqual(got[1] | (got[2] << 8), 9003)

    def test_the_last_line_need_not_be_terminated(self):
        got, _ = self.assemble("nop\nlda #$12")
        self.assertEqual(got, bytes([0xEA, 0xA9, 0x12]))

    # ---- speed ---------------------------------------------------------

    def test_reports_a_cycle_count(self):
        """The measurement is real, and scales with the work."""
        small = a_program(["lda #$12"] * 200)
        large = a_program(["lda #$12"] * 2000)

        _, small_cycles = self.assemble(small)
        _, large_cycles = self.assemble(large)

        self.assertGreater(small_cycles, 0)
        # Ten times the input inside a factor of two of ten times the cycles,
        # which is the claim that the assembler is linear in its input.
        ratio = large_cycles / small_cycles
        self.assertGreater(ratio, 5, "cycles did not scale with the input")
        self.assertLess(ratio, 20, "cycles grew faster than the input")

        per_byte = large_cycles / len(large)
        print("\n    %d lines, %d bytes: %d cycles, %.1f cycles/byte, "
              "%.3fs at 8MHz"
              % (2000, len(large), large_cycles, per_byte,
                 large_cycles / 8e6))


if __name__ == "__main__":
    unittest.main()
