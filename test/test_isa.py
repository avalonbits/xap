"""Guards the generated instruction table.

src/isa.inc is committed rather than built on the fly, so it can rot: a hand
edit, a change to the generator, or a different 64tass could all leave it
saying something the assembler then faithfully encodes. Re-deriving the table
costs under a second for the whole instruction set, so the test does exactly
what the generator does and requires the answer to be identical.

It also re-checks the invariants directly rather than trusting that the
generator checked them, since a generator bug would otherwise be committed
along with the table it produced.
"""

import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import gen_isa as g

ROOT = os.path.join(os.path.dirname(__file__), "..")
ISA = os.path.join(ROOT, "src", "isa.inc")
TASS = os.environ.get("TASS", "64tass")

# The W65C02S leaves 44 of the 256 opcodes reserved.
OPCODE_COUNT = 212


class TestISA(unittest.TestCase):
    table = None

    @classmethod
    def setUpClass(cls):
        tass = g.Tass(TASS)
        if tass.encode("nop") is None:
            raise unittest.SkipTest("64tass not available (set $TASS)")
        cls.table = g.probe(tass)

    def test_committed_file_matches_the_generator(self):
        """The committed table is what the generator produces, byte for byte."""
        buf = io.StringIO()
        g.emit(dict(self.table), buf)
        with open(ISA) as fh:
            self.assertEqual(fh.read(), buf.getvalue(),
                             "src/isa.inc is stale -- run 'make isa'")

    def test_every_opcode_is_present_and_unique(self):
        seen = {}
        for name, row in self.table.items():
            for mode, opcode in row.items():
                self.assertNotIn(
                    opcode, seen,
                    "$%02X produced by both %s and %s"
                    % (opcode, seen.get(opcode), name))
                seen[opcode] = name
        self.assertEqual(len(seen), OPCODE_COUNT)

    def test_py65_agrees(self):
        checked = g.crosscheck(dict(self.table))
        # py65 has no BBRx/BBSx and no STP, so it can confirm 195 of the 212.
        self.assertEqual(checked, 195)

    def test_modes_are_the_length_they_claim(self):
        """Each mode's declared length is what 64tass actually emits."""
        tass = g.Tass(TASS)
        for name, template, length, _ in g.MODES:
            if template is None:
                continue
            # LDA reaches every mode with an operand; the bare forms are
            # checked through NOP and ASL instead.
            for m in ("lda", "nop", "asl", "jmp", "bcc", "ldx"):
                code = tass.encode(template.format(m=m))
                if code is not None and len(code) == length:
                    break
            else:
                self.fail("no probe reached mode %s" % name)

    def test_the_ident_table_agrees_with_the_class_table(self):
        """The .isident macro reads xapIdentUpper and takes zero to mean
        "not part of a name", instead of reading the class table and
        masking off XAP_CLASS_IDENT.

        That is only correct while the two describe the same set of
        characters, and they are generated independently -- one to fold
        case while a name is read, the other to classify a character for
        the line parser. So the equivalence is asserted rather than
        assumed, over all 256 values.
        """
        tables = self.tables()
        ident = tables["xapIdentUpper"]
        klass = tables["xapClass"]
        self.assertEqual(len(ident), 256)
        self.assertEqual(len(klass), 256)
        for b in range(256):
            self.assertEqual(bool(ident[b]), bool(klass[b] & 0x04),
                             "$%02X: xapIdentUpper says %d, xapClass says %d"
                             % (b, ident[b], klass[b]))

    @staticmethod
    def tables():
        """The byte tables in src/isa.inc, by label."""
        import re

        out = {}
        name = None
        with open(ISA) as fh:
            for line in fh:
                label = re.match(r"^(\w+):", line)
                if label:
                    name = label.group(1)
                    out[name] = []
                    continue
                body = re.match(r"\s+\.byte\s+(.*)", line)
                if body and name:
                    values = [v.strip() for v in body.group(1).split(",")]
                    if all(re.fullmatch(r"\$[0-9a-f]{2}", v) for v in values):
                        out[name] += [int(v[1:], 16) for v in values]
                    else:
                        # A table of expressions rather than bytes, such as
                        # the opcode row addresses. Not one of these.
                        out.pop(name, None)
                        name = None
                elif not line.strip():
                    name = None

        return out

    def test_bit_families_stay_arithmetic(self):
        """RMB3 is RMB0 plus 3*16, and the table depends on that."""
        tass = g.Tass(TASS)
        for stem, mode in g.BITOPS.items():
            first = None
            for bit in range(8):
                line = ("%s %d,$34" if mode == "zp" else "%s %d,$34,*") % (stem, bit)
                code = tass.encode(line)
                self.assertIsNotNone(code, "%s%d did not assemble" % (stem, bit))
                if first is None:
                    first = code[0]
                self.assertEqual(code[0], first + bit * 0x10,
                                 "%s%d breaks the arithmetic rule" % (stem, bit))


if __name__ == "__main__":
    unittest.main()
