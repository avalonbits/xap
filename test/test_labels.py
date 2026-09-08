"""Labels, and the fixups that wait for them.

A label used before it is defined is where the single pass has to earn its
keep: there is no second pass to come back and settle it, so the reference
leaves a hole, records what has to go in it, and the definition fills every
hole that was waiting.

Bytes are checked against 64tass wherever the two agree on what the answer is.
The one place they do not is deliberate and has its own test at the bottom.
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from harness import Error, Xap

TASS = os.environ.get("TASS", "64tass")
ORIGIN = 0x1000

# The codes src/xap.asm assigns.
E_RANGE = 0x07
E_MODE = 0x08
E_UNDEF = 0x23
E_REDEF = 0x24
E_LABEL = 0x25


class TestLabels(unittest.TestCase):
    xap = None

    @classmethod
    def setUpClass(cls):
        cls.xap = Xap()

    def tass(self, source, origin=ORIGIN):
        d = tempfile.mkdtemp(prefix="xap_lbl_")
        try:
            src = os.path.join(d, "s.asm")
            out = os.path.join(d, "s.bin")
            # 64tass takes the bit number of the Rockwell instructions as a
            # first operand where xap attaches it to the mnemonic.
            source = re.sub(r"\b(rmb|smb|bbr|bbs)([0-7])\s+", r"\1 \2,",
                            source, flags=re.I)
            with open(src, "w") as fh:
                fh.write("* = $%04X\n" % origin + source)
            r = subprocess.run([TASS, "--mw65c02", "-q", "-b", "-o", out, src],
                               capture_output=True)
            if r.returncode != 0:
                self.fail("64tass rejected:\n%s\n%s"
                          % (source, r.stderr.decode()))
            with open(out, "rb") as fh:
                return fh.read()
        finally:
            import shutil
            shutil.rmtree(d, ignore_errors=True)

    def same(self, source):
        """xap and 64tass produce the same bytes for this."""
        self.assertEqual(self.xap.assemble(source), self.tass(source), source)

    # ---- defining ------------------------------------------------------

    def test_a_label_is_where_it_stands(self):
        self.same("a:\n  jmp a\n")
        self.same("  nop\nb:\n  jmp b\n")
        self.same("  nop\n  nop\nc:\n  jmp c\n")

    def test_the_colon_is_optional(self):
        self.assertEqual(self.xap.assemble("a:\n  jmp a\n"),
                         self.xap.assemble("a\n  jmp a\n"))

    def test_a_label_may_share_its_line_with_an_instruction(self):
        self.same("here: nop\n  jmp here\n")
        self.same("here:\tnop\n  jmp here\n")

    def test_a_label_may_be_indented(self):
        """A word that is not an instruction is a label wherever it sits."""
        self.same("  here:\n  jmp here\n")

    def test_case_is_ignored(self):
        """FOO and foo are one label, which is what the ROM assembler does."""
        self.assertEqual(self.xap.assemble("Foo:\n  jmp FOO\n"),
                         self.xap.assemble("foo:\n  jmp foo\n"))
        self.assertEqual(self.xap.assemble("aB:\n  jmp Ab\n"),
                         bytes([0x4C, 0x00, 0x10]))

    def test_a_label_may_hold_digits(self):
        self.same("loop1:\n  jmp loop1\n")
        self.same("x9y8:\n  jmp x9y8\n")

    def test_defining_one_twice_is_an_error(self):
        for source in ("dup:\ndup:\n", "dup:\n  nop\ndup:\n", "d:\nd\n"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, E_REDEF, source)

    def test_a_name_that_is_too_long_is_an_error(self):
        with self.assertRaises(Error) as e:
            self.xap.assemble("%s:\n" % ("a" * 40))
        self.assertEqual(e.exception.code, E_LABEL)

    # ---- backward references -------------------------------------------

    def test_a_label_already_defined_is_used_straight_away(self):
        self.same("a:\n  lda a\n  sta a\n  jsr a\n")
        self.same("a:\n  jmp (a)\n")
        self.same("a:\n  lda a,x\n  lda a,y\n")

    def test_a_backward_branch(self):
        self.same("a:\n  bne a\n  beq a\n  bra a\n")
        self.same("a:\n" + "  nop\n" * 60 + "  bne a\n")

    # ---- forward references --------------------------------------------

    def test_a_forward_reference_is_filled_in(self):
        self.same("  jmp a\na:\n  nop\n")
        self.same("  jsr a\n  nop\na:\n")
        self.same("  lda a\na:\n")

    def test_several_references_to_one_label(self):
        self.same("  jmp a\n  jmp a\n  jmp a\na:\n")

    def test_references_in_both_directions(self):
        self.same("a:\n  jmp b\nb:\n  jmp a\n")
        self.same("a:\n  jmp b\n  jmp a\nb:\n  jmp a\n  jmp b\n")

    def test_a_forward_branch(self):
        self.same("  bne a\na:\n")
        self.same("  bne a\n  nop\na:\n")
        self.same("  bne a\n" + "  nop\n" * 60 + "a:\n")

    def test_a_forward_bit_branch(self):
        """BBRn measures from after its third byte, and still does."""
        self.same("  bbr0 $34,a\n  nop\na:\n")
        self.same("  bbs7 $12,a\n" + "  nop\n" * 40 + "a:\n")

    def test_a_forward_branch_out_of_reach(self):
        source = "  bne a\n" + "  nop\n" * 200 + "a:\n"
        with self.assertRaises(Error) as e:
            self.xap.assemble(source)
        self.assertEqual(e.exception.code, E_RANGE)

    def test_a_label_never_defined(self):
        for source in ("  jmp a\n", "  bne a\n", "  lda a\n  nop\n"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, E_UNDEF, source)

    def test_many_labels(self):
        """More than a hash bucket's worth, so chains get walked."""
        source = "".join("l%d:\n  jmp l%d\n" % (i, i) for i in range(200))
        self.same(source)

    def test_many_forward_references_to_one_label(self):
        source = "  jmp e\n" * 300 + "e:\n"
        self.same(source)

    # ---- where a lone A goes -------------------------------------------

    def test_a_lone_a_is_the_accumulator_only_where_that_mode_exists(self):
        """Where "a" is both a label and a register, xap reads the register.

        The ROM assembler settles this the same way, and unconditionally:
        its address mode parser takes a lone A as the accumulator before it
        looks at anything else, so a label called A is simply unreachable
        there. xap narrows that to the six instructions that have the mode,
        which leaves "jmp a" meaning the label -- JMP has no accumulator
        form, so there is nothing else it could be.

        64tass, having more than one pass, decides the other way and reads
        the label. This is the one ambiguity in the syntax where the two
        cannot both be right, and matching the assembler xap replaces
        matters more.
        """
        self.assertEqual(self.xap.assemble("a:\n  asl a\n"), bytes([0x0A]))
        self.assertEqual(self.xap.assemble("a:\n  inc a\n"), bytes([0x1A]))

        # Everything without the mode reads it as the label it is.
        self.same("a:\n  jmp a\n")
        self.same("a:\n  lda a\n")
        self.same("a:\n  jsr a\n")

    # ---- local labels --------------------------------------------------

    def test_a_local_label_lives_between_two_global_ones(self):
        """64tass has the same rule for an underscore name, so it can say."""
        self.same("g:\n_a:\n  jmp _a\n")
        self.same("g:\n  jmp _a\n_a:\n")
        self.same("g:\n  bne _s\n  nop\n_s:\n  nop\n")

    def test_the_same_local_name_in_two_scopes(self):
        """Which is the whole point of them."""
        self.same("g1:\n_a:\n  jmp _a\ng2:\n_a:\n  jmp _a\n")
        self.same("".join("g%d:\n_a:\n  jmp _a\n" % i for i in range(50)))

    def test_a_local_cannot_be_reached_from_another_scope(self):
        for source in ("g1:\n  jmp _a\ng2:\n_a:\n",
                       "g1:\n_a:\ng2:\n  jmp _a\n"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, E_UNDEF, source)

    def test_an_undefined_local_is_caught_where_its_scope_ends(self):
        """At the global label that ends it, or at the end of the file if
        none ever comes -- either way it is not left to be a mystery."""
        for source in ("g1:\n  jmp _a\ng2:\n", "g:\n  jmp _a\n  nop\n"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, E_UNDEF, source)

    def test_a_local_may_be_defined_before_any_global(self):
        self.same("_a:\n  jmp _a\n")

    def test_a_local_defined_twice_in_one_scope(self):
        with self.assertRaises(Error) as e:
            self.xap.assemble("g:\n_a:\n_a:\n")
        self.assertEqual(e.exception.code, E_REDEF)

    def test_an_at_sign_starts_one_too(self):
        """Which 64tass does not accept, so this asserts on xap alone.

        The ROM assembler's manual names both: "labels beginning with
        underscore (_) or at sign (@) are local labels".
        """
        self.assertEqual(self.xap.assemble("g:\n@loop:\n  bne @loop\n"),
                         bytes([0xD0, 0xFE]))
        self.assertEqual(self.xap.assemble("g1:\n@a:\ng2:\n@a:\n"), b"")

    def test_a_name_may_hold_a_period(self):
        """The manual's character set: alphanumerics, underscore, at sign
        and period, after an alphabetic first character.

        64tass reads a period as a member operator and rejects the name
        outright, so this asserts on xap alone. Following the assembler xap
        stands in for matters more.
        """
        self.assertEqual(self.xap.assemble("a.b:\n  jmp a.b\n"),
                         bytes([0x4C, 0x00, 0x10]))
        self.same("a_b:\n  jmp a_b\n")

    def test_globals_are_still_reachable_from_inside_a_scope(self):
        self.same("g:\n_a:\n  jmp g\n  jmp _a\n")

    def test_many_locals_in_one_scope(self):
        source = "g:\n" + "".join("_l%d:\n  jmp _l%d\n" % (i, i)
                                  for i in range(25))
        self.same(source)

    # ---- deciding how wide a forward reference is ----------------------

    def test_a_forward_reference_above_zero_page_is_absolute(self):
        """And is known to be, without knowing the value.

        A label defined later sits at or above the program counter, because
        the counter only moves forward. So once past the zero page a forward
        reference cannot be a zero page address, and its size is settled
        where it is read.
        """
        got = self.xap.assemble("  lda fwd\nfwd:\n", origin=0x1000)
        self.assertEqual(got, bytes([0xAD, 0x03, 0x10]))
        self.same("  lda fwd\n  nop\nfwd:\n")

    def test_a_forward_reference_inside_zero_page_stays_narrow(self):
        """Where it cannot be settled, the narrow form is tried first."""
        for source in ("  lda fwd\nfwd:\n",
                       "  lda fwd\n  nop\nfwd:\n",
                       "  lda fwd\n  jmp fwd\nfwd:\n",
                       "  ldx fwd\n  sta fwd\nfwd:\n"):
            self.assertEqual(self.xap.assemble(source, origin=0x0010),
                             self.tass(source, origin=0x0010), source)

    def test_a_guess_that_was_wrong_widens(self):
        """The image shifts up a byte and every label above it follows."""
        for source in (
            "  lda fwd\n" + "  nop\n" * 300 + "fwd:\n",
            "a:\n  lda f\n" + "  nop\n" * 300 + "f:\n  jmp a\n  jmp f\n",
            "  lda f1\n  ldx f2\n" + "  nop\n" * 300 + "f1:\nf2:\n",
        ):
            self.assertEqual(self.xap.assemble(source, origin=0x0010),
                             self.tass(source, origin=0x0010), source[:40])

    def test_a_second_guess_after_the_first_settled(self):
        """Nothing is filled in until the file is read, once anything has
        been guessed at all.

        Filling holes as soon as a symbol arrives is wrong here: a later
        guess that turns out badly moves code, and moves labels that have
        already been written into holes. The fuzzer found this by producing
        a program with a settled guess early and another one after it.
        """
        source = ("  lda f1\n" + "  nop\n" * 100 + "f1:\n"
                  "  lda f2\n" + "  nop\n" * 300 + "f2:\n")
        self.assertEqual(self.xap.assemble(source, origin=0x0010),
                         self.tass(source, origin=0x0010))

    def test_a_reference_already_settled_can_still_move(self):
        """A backward reference is not final once anything has been guessed.

        The value is known when it is read, so it goes straight into the
        code -- and then a guess further up turns out wrong, the image
        shifts, and the label it named has moved. It has to be left as a
        hole like a forward reference, and only the width comes from the
        value.

        This was wrong from the day sizes started being guessed. Both
        global and local labels had it; local labels only made it easier
        to run into.
        """
        for source, what in (
            ("  lda f\n" + "  nop\n" * 300 + "s:\n  jmp s\nf:\n", "global"),
            ("g:\n  lda f\n" + "  nop\n" * 300 + "_s:\n  jmp _s\nf:\n",
             "local"),
            ("  lda f\n" + "  nop\n" * 300 + "s:\n  bne s\nf:\n", "branch"),
        ):
            self.assertEqual(self.xap.assemble(source, origin=0x0010),
                             self.tass(source, origin=0x0010), what)

    def test_a_mnemonic_with_one_width_never_guesses(self):
        """JMP has no zero page mode, so its size is settled whatever the
        value turns out to be -- even in zero page."""
        self.assertEqual(self.xap.assemble("  jmp fwd\nfwd:\n", origin=0x0010),
                         bytes([0x4C, 0x13, 0x00]))


if __name__ == "__main__":
    unittest.main()
