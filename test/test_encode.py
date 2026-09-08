"""Differential tests: xap against 64tass, instruction by instruction.

The headline test assembles every (mnemonic, address mode) pair in the
W65C02S with both assemblers and compares the bytes. That is the whole of
what this stage of xap claims to do, so it is the whole of what is checked --
212 opcodes, no sampling.

The rest are the cases where the encoding turns on something the corpus would
catch but would not localise: which width was chosen, how far a branch
reaches, and what happens to input that is not an instruction.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))

import gen_isa as g
from harness import Error, Xap

TASS = os.environ.get("TASS", "64tass")

ORIGIN = 0x1000      # what harness.Xap and gen_isa.Tass both assemble at
TARGET = 0x1010      # a branch target within reach of it

# How each mode is written for xap. These differ from the generator's probe
# templates in two places: xap has no "*" for the program counter yet, so a
# branch needs a literal target, and xap spells the Rockwell bit instructions
# with the digit attached.
XAP_TEMPLATE = {
    "impacc": "{m}",
    "imm":    "{m} #$12",
    "zp":     "{m} $34",
    "zpx":    "{m} $34,x",
    "zpy":    "{m} $34,y",
    "izp":    "{m} ($34)",
    "izx":    "{m} ($34,x)",
    "izy":    "{m} ($34),y",
    "abs":    "{m} $5678",
    "abx":    "{m} $5678,x",
    "aby":    "{m} $5678,y",
    "iabs":   "{m} ($5678)",
    "iabx":   "{m} ($5678,x)",
    "rel":    "{m} $%04X" % TARGET,
    "zprel":  "{m} $34,$%04X" % TARGET,
}

# The same instruction as 64tass wants it written.
TASS_TEMPLATE = dict(XAP_TEMPLATE)
TASS_TEMPLATE["rel"] = "{m} $%04X" % TARGET


def tass_line(name, mode):
    """The 64tass spelling of one instruction."""
    stem, digit = name[:3].lower(), name[3:]
    if digit:
        # 64tass takes the bit number as a first operand: "rmb 3,$34".
        if mode == "zprel":
            return "%s %s,$34,$%04X" % (stem, digit, TARGET)

        return "%s %s,$34" % (stem, digit)

    # 64tass takes a bare ASL as the accumulator form but insists on "inc a".
    # xap accepts either for all six, which is what the accumulator test
    # covers; here the oracle has to be written the way it wants.
    if mode == "impacc" and stem in g.ACC_FORM:
        return "%s a" % stem

    return TASS_TEMPLATE[mode].format(m=name.lower())


class TestEncoding(unittest.TestCase):
    xap = None
    table = None
    tass = None

    @classmethod
    def setUpClass(cls):
        cls.tass = g.Tass(TASS)
        if cls.tass.encode("nop") is None:
            raise unittest.SkipTest("64tass not available (set $TASS)")
        cls.table = g.probe(cls.tass)
        cls.xap = Xap()

    def test_every_opcode_matches_64tass(self):
        """All 212 W65C02S opcodes, byte for byte against the oracle."""
        inv = {v: k for k, v in g.MODE_INDEX.items()}
        checked = 0
        bad = []

        for name in sorted(self.table):
            for mode_index in sorted(self.table[name]):
                mode = inv[mode_index]
                source = XAP_TEMPLATE[mode].format(m=name.lower())
                want = self.tass.encode(tass_line(name, mode))
                self.assertIsNotNone(want, "64tass rejected %r" % name)
                try:
                    got = self.xap.assemble(source, origin=ORIGIN)
                except Error as e:
                    bad.append("%-14s xap failed $%02X, 64tass %s"
                               % (source, e.code, want.hex()))
                    continue
                if got != want:
                    bad.append("%-14s xap %s, 64tass %s"
                               % (source, got.hex(), want.hex()))
                checked += 1

        self.assertEqual(bad, [], "\n" + "\n".join(bad))
        self.assertEqual(checked, 212)

    def test_accumulator_may_be_written_either_way(self):
        """ASL and ASL A are the same instruction, and so are INC and INC A."""
        for m in sorted(g.ACC_FORM):
            bare = self.xap.assemble(m)
            spelt = self.xap.assemble(m + " a")
            self.assertEqual(bare, spelt, m)
            self.assertEqual(bare, self.tass.encode(m + " a"), m)

    def test_case_is_ignored(self):
        for source in ("LDA #$12", "Lda #$12", "lda #$12", "RmB3 $34"):
            self.assertEqual(self.xap.assemble(source),
                             self.xap.assemble(source.lower()), source)

    # ---- width selection ----------------------------------------------

    def test_width_follows_the_value_not_the_spelling(self):
        """$0034 is zero page, because it is 52, not because of its digits."""
        self.assertEqual(self.xap.assemble("lda $0034"), bytes([0xA5, 0x34]))
        self.assertEqual(self.xap.assemble("lda $34"), bytes([0xA5, 0x34]))
        self.assertEqual(self.xap.assemble("lda 52"), bytes([0xA5, 0x34]))
        self.assertEqual(self.xap.assemble("lda $0134"),
                         bytes([0xAD, 0x34, 0x01]))

    def test_a_mode_the_mnemonic_lacks_widens(self):
        """JMP has absolute indirect and no zero page indirect."""
        self.assertEqual(self.xap.assemble("jmp ($34)"),
                         bytes([0x6C, 0x34, 0x00]))

    def test_indirect_y_is_zero_page_only(self):
        """($34),y has no absolute form, so a large operand is an error."""
        self.assertEqual(self.xap.assemble("lda ($34),y"), bytes([0xB1, 0x34]))
        with self.assertRaises(Error) as e:
            self.xap.assemble("lda ($1234),y")
        self.assertEqual(e.exception.code, 0x22)        # XAP_EVALUE

    def test_a_mode_that_does_not_exist_is_rejected(self):
        # "lda a" is not here any more: since labels arrived, a lone A is
        # only the accumulator for the six instructions that have that
        # mode, and for everything else it is a label of that name.
        for source in ("ldx $34,x", "sta #$12", "tax $34", "inx #$01"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, 0x08, source)   # XAP_EMODE

    # ---- branches ------------------------------------------------------

    def test_branch_is_measured_from_the_next_instruction(self):
        self.assertEqual(self.xap.assemble("bcc $1002", origin=0x1000),
                         bytes([0x90, 0x00]))
        self.assertEqual(self.xap.assemble("bcc $1000", origin=0x1000),
                         bytes([0x90, 0xFE]))
        self.assertEqual(self.xap.assemble("bcc $1081", origin=0x1000),
                         bytes([0x90, 0x7F]))
        self.assertEqual(self.xap.assemble("bcc $0F82", origin=0x1000),
                         bytes([0x90, 0x80]))

    def test_a_branch_out_of_reach_is_an_error(self):
        for target in (0x1082, 0x0F81):
            with self.assertRaises(Error, msg=hex(target)) as e:
                self.xap.assemble("bcc $%04X" % target, origin=0x1000)
            self.assertEqual(e.exception.code, 0x07)    # XAP_ERANGE

    def test_bit_branch_is_three_bytes_long(self):
        """BBR0 is measured from after its third byte, not its second."""
        self.assertEqual(self.xap.assemble("bbr0 $34,$1003", origin=0x1000),
                         bytes([0x0F, 0x34, 0x00]))
        self.assertEqual(self.xap.assemble("bbr3 $12,$1003", origin=0x1000),
                         bytes([0x3F, 0x12, 0x00]))

    # ---- numbers -------------------------------------------------------

    def test_number_bases(self):
        self.assertEqual(self.xap.assemble("lda #$1f"), bytes([0xA9, 0x1F]))
        self.assertEqual(self.xap.assemble("lda #%00011111"), bytes([0xA9, 0x1F]))
        self.assertEqual(self.xap.assemble("lda #31"), bytes([0xA9, 0x1F]))
        self.assertEqual(self.xap.assemble("lda #'A'"), bytes([0xA9, 0x41]))
        self.assertEqual(self.xap.assemble("lda $ffff"),
                         bytes([0xAD, 0xFF, 0xFF]))
        self.assertEqual(self.xap.assemble("lda 65535"),
                         bytes([0xAD, 0xFF, 0xFF]))

    def test_a_malformed_number_is_an_error(self):
        for source in ("lda #$", "lda #%", "lda #'", "lda #'ab", "lda #"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, 0x09, source)    # XAP_EEXPR

    # ---- lines ---------------------------------------------------------

    def test_lines_comments_and_blanks(self):
        self.assertEqual(self.xap.assemble(""), b"")
        self.assertEqual(self.xap.assemble("   ; nothing here"), b"")
        self.assertEqual(
            self.xap.assemble("\tnop ; a comment\n\n  ; another\n\tnop\n"),
            bytes([0xEA, 0xEA]))
        self.assertEqual(self.xap.assemble("nop\r\nnop\r\n"),
                         bytes([0xEA, 0xEA]))

    def test_runs_of_spaces_and_tabs_between_every_token(self):
        """Every place the scanner skips whitespace, given more than one.

        The skipper is entered only once the character under the cursor has
        already been classified as a space or a tab, so it steps past that
        one before looking again. An off-by-one there eats a character of
        the token that follows, or leaves the cursor on the last space --
        neither of which a single separator can show.
        """
        for source, want in (
            ("        nop", [0xEA]),
            ("\t\t\t\tnop", [0xEA]),
            (" \t \t nop", [0xEA]),
            ("lda    \t  #$12", [0xA9, 0x12]),
            ("lda   $34  ,   x", [0xB5, 0x34]),
            ("lda   (  $34  ,  x  )", [0xA1, 0x34]),
            ("lda   (  $34  )  ,  y", [0xB1, 0x34]),
            ("lda   (  $34  )", [0xB2, 0x34]),
            ("bbr0   $34  ,  $1003", [0x0F, 0x34, 0x00]),
            ("nop   \t   ; a comment", [0xEA]),
            ("   \t   \n   \t   nop", [0xEA]),
        ):
            self.assertEqual(self.xap.assemble(source, origin=0x1000),
                             bytes(want), repr(source))

    def test_comments(self):
        """A semicolon ends the line, wherever it is and whatever follows."""
        for source, want in (
            ("nop ; a comment", [0xEA]),
            ("nop;no space before it", [0xEA]),
            ("; nothing but a comment", []),
            ("      ; indented, still nothing", []),
            ("nop ; one ; two ; three", [0xEA]),
            ("lda #$12 ; c\nnop ; c\n", [0xA9, 0x12, 0xEA]),
            ("nop ; before a CRLF\r\nnop", [0xEA, 0xEA]),
        ):
            self.assertEqual(self.xap.assemble(source), bytes(want), source)

    def test_control_characters_inside_a_comment(self):
        """The comment scan passes over anything below space that is not a
        line ending, which is how a tab in a comment stays in the comment."""
        for source, want in (
            ("nop ;\tcomment with a tab\nnop", [0xEA, 0xEA]),
            ("nop ; and a formfeed\x0c here\nnop", [0xEA, 0xEA]),
            ("nop ;\t\t\t\nnop", [0xEA, 0xEA]),
            ("nop ; running to the end of the text", [0xEA]),
            ("\t; a tab-indented comment line\nnop", [0xEA]),
        ):
            self.assertEqual(self.xap.assemble(source), bytes(want), repr(source))

    def test_a_semicolon_in_quotes_is_not_a_comment(self):
        """The one case where the rule is not just "semicolon ends it".

        The ROM assembler's manual is explicit that a semicolon delimits a
        comment only outside quotes, so this has to keep working.
        """
        self.assertEqual(self.xap.assemble("lda #';'"), bytes([0xA9, 0x3B]))
        self.assertEqual(self.xap.assemble("lda #';' ; and a real one"),
                         bytes([0xA9, 0x3B]))

    def test_several_instructions_advance_the_program_counter(self):
        """Each branch is relative to its own address, not the first."""
        self.assertEqual(
            self.xap.assemble("bcc $1004\nbcc $1004\n", origin=0x1000),
            bytes([0x90, 0x02, 0x90, 0x00]))

    def test_a_word_that_is_not_an_instruction_is_a_label(self):
        """Which is how a label is told from an instruction at all.

        Robson's spec puts it plainly: a label is an unknown mnemonic, or a
        word ending in a colon. So these define labels rather than failing,
        and the failure only comes at the end for the one never defined.
        """
        for source in ("frob", "ld", "ldaa", "rmb3x", "x", "frob:"):
            self.assertEqual(self.xap.assemble(source), b"", source)

    def test_a_bad_bit_number_is_rejected(self):
        for source in ("rmb8 $34", "rmb $34", "bbr9 $34,$1003"):
            with self.assertRaises(Error, msg=source) as e:
                self.xap.assemble(source)
            self.assertEqual(e.exception.code, 0x21, source)      # XAP_EBIT

    def test_trailing_junk_is_rejected(self):
        for source in ("nop nop", "lda $34 $34", "lda $34,x)"):
            with self.assertRaises(Error, msg=source):
                self.xap.assemble(source)


if __name__ == "__main__":
    unittest.main()
