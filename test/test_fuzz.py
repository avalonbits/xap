"""Differential fuzzing: random programs through xap and through 64tass.

The hand-written tests cover the cases somebody thought of. This covers the
ones nobody did, by generating programs that mix instructions, labels and
references in every direction and requiring the two assemblers to agree byte
for byte.

Seeded, so a failure is reproducible and can be pasted straight into
test_labels.py as a regression. FUZZ_SEED picks a different run and FUZZ_CASES
makes it longer.

Run at two origins. Above the zero page, every forward reference is settled as
absolute the moment it is read, because a label defined later cannot be below
the program counter. Inside the zero page it cannot be, so the assembler
guesses narrow and widens when the guess turns out wrong -- shifting the image
and moving every label above the shift. That path only exists at a zero page
origin, and it is where the interesting failures are.

Branch reachability is worked out with the wide form of every instruction,
which is an upper bound on the distance: shrinking only brings a target
closer, so a branch the generator believes is in range really is.

Programs are generated so that both assemblers must agree on them, which rules
out three things on purpose:

  A label called "a", because a lone A is the accumulator to xap and the
  label to 64tass -- a deliberate divergence with its own test.

  Local labels spelled with an at sign, and any name holding a period.
  64tass takes neither, so only the underscore form of a local is
  generated; both divergences have their own tests.

  Zero page labels, because there are none yet: every label is a code address
  at or above the origin, so a forward reference is absolute either way. When
  assignments arrive this gets more interesting.

  Branches out of reach, which are an error rather than a difference.
"""

import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

from harness import Error, Xap

TASS = os.environ.get("TASS", "64tass")
SEED = int(os.environ.get("FUZZ_SEED", "20260907"))
CASES = int(os.environ.get("FUZZ_CASES", "150"))

ORIGIN = 0x1000
ZP_ORIGIN = 0x0010

# (template, length). {L} takes a label, {B} a byte, {W} a word.
INSTRUCTIONS = [
    ("nop", 1), ("inx", 1), ("dey", 1), ("pha", 1), ("plp", 1),
    ("asl a", 1), ("clc", 1), ("rts", 1), ("tax", 1),
    ("lda #${B:02x}", 2), ("cmp #${B:02x}", 2), ("ldx #${B:02x}", 2),
    ("lda ${B:02x}", 2), ("sta ${B:02x}", 2), ("inc ${B:02x},x", 2),
    ("lda (${B:02x}),y", 2), ("ora (${B:02x},x)", 2), ("adc (${B:02x})", 2),
    ("lda ${W:04x}", 3), ("sta ${W:04x},x", 3), ("ldx ${W:04x},y", 3),
    ("jmp (${W:04x})", 3), ("rmb3 ${B:02x}", 2),
]

# Instructions whose operand can be a label, and how they reach it.
ABSOLUTE = [("jmp {L}", 3), ("jsr {L}", 3), ("lda {L}", 3),
            ("sta {L}", 3), ("cmp {L}", 3), ("lda {L},x", 3),
            ("jmp ({L})", 3)]
BRANCHES = [("bne {L}", 2), ("beq {L}", 2), ("bcc {L}", 2),
            ("bra {L}", 2), ("bmi {L}", 2)]
BIT_BRANCH = [("bbr0 ${B:02x},{L}", 3), ("bbs5 ${B:02x},{L}", 3)]


def to_tass(source):
    """64tass takes the Rockwell bit number as a first operand."""
    return re.sub(r"\b(rmb|smb|bbr|bbs)([0-7])\s+", r"\1 \2,", source,
                  flags=re.I)


def program(rng, origin=ORIGIN):
    """A random program, and the labels it defines.

    Built in two passes over a list of items rather than as text, because a
    branch has to reach its target and that cannot be known until every
    item's length is. The first pass fixes the shapes and so the addresses;
    the second fills in which label each reference names.
    """
    n = rng.randint(4, 60)
    items = []          # (kind, template, length, label defined here)
    labels = []         # (name, address)

    for i in range(n):
        r = rng.random()
        if r < 0.25:
            # A label of its own, or sharing a line with an instruction.
            # Some are local: an underscore name, which lives only until
            # the next global one, so two scopes can hold the same name.
            if rng.random() < 0.35:
                name = "_s%d" % rng.randrange(4)
            else:
                name = "l%d" % i
            if rng.random() < 0.3:
                text, length = rng.choice(INSTRUCTIONS)
                items.append(("labelled", text, length, name))
            else:
                items.append(("label", "", 0, name))
        elif r < 0.45:
            text, length = rng.choice(ABSOLUTE)
            items.append(("absolute", text, length, None))
        elif r < 0.60:
            text, length = rng.choice(BRANCHES)
            items.append(("branch", text, length, None))
        elif r < 0.65:
            text, length = rng.choice(BIT_BRANCH)
            items.append(("branch", text, length, None))
        elif r < 0.72:
            items.append(("blank", "", 0, None))
        elif r < 0.80:
            items.append(("comment", "; %d" % i, 0, None))
        else:
            text, length = rng.choice(INSTRUCTIONS)
            items.append(("plain", text, length, None))

    # Where everything lands, and so where every label is.
    pc = origin
    address = []
    scope = 0
    scopes = []             # which scope each item sits in
    seen = set()            # (scope, name), to catch a repeat definition
    keep = []
    for n, (kind, text, length, name) in enumerate(items):
        address.append(pc)
        if name and not name.startswith("_"):
            scope += 1      # a global label ends the scope before it
        scopes.append(scope)
        if name:
            if (scope, name) in seen:
                # The same name twice in one scope is an error in both
                # assemblers, so do not generate it: drop the definition
                # and leave the line as an ordinary one.
                items[n] = ("plain" if kind == "labelled" else "blank",
                            text, length, None)
                continue
            seen.add((scope, name))
            labels.append((name, pc, scope))
        pc += length

    if not labels:
        return None, None

    lines = []
    for i, (kind, text, length, name) in enumerate(items):
        here = address[i]
        if kind == "label":
            lines.append("%s:" % name)
            continue
        if kind == "blank":
            lines.append("")
            continue
        if kind == "comment":
            lines.append("    " + text)
            continue

        # A local is only in view from inside the scope it was defined in.
        mine = [(nm, at) for nm, at, sc in labels
                if not nm.startswith("_") or sc == scopes[i]]

        if kind == "branch":
            # Only a label the branch can actually reach, measured from the
            # instruction after it.
            reachable = [nm for nm, at in mine
                         if -128 <= at - (here + length) <= 127]
            if not reachable:
                lines.append("    nop")
                continue
            target = rng.choice(reachable)
        elif kind == "absolute":
            if not mine:
                lines.append("    nop")
                continue
            target = rng.choice(mine)[0]
        else:
            target = None

        body = text.format(L=target, B=rng.randrange(256),
                           W=rng.randrange(0x1000, 0x8000))
        if kind == "labelled":
            lines.append("%s: %s" % (name, body))
        else:
            lines.append("    " + body)

    return "\n".join(lines) + "\n", labels


class TestFuzz(unittest.TestCase):
    xap = None
    dir = None

    @classmethod
    def setUpClass(cls):
        cls.xap = Xap()
        cls.dir = tempfile.mkdtemp(prefix="xap_fuzz_")

    def test_every_template_is_a_real_instruction(self):
        """Checked once, so a bad template fails here and says which.

        "ldy $nnnn,y" was in the list to begin with. LDY has no such mode,
        and the only sign of it was 64tass rejecting one generated program
        in eight with the seed pointing at the whole program rather than at
        the line that was wrong.
        """
        bad = []
        for text, length in INSTRUCTIONS + ABSOLUTE + BRANCHES + BIT_BRANCH:
            body = text.format(L="target", B=0x34, W=0x5678)
            source = "    %s\ntarget:\n" % body
            got, err = self.tass(source)
            if got is None:
                bad.append("%-22s %s" % (body, err.strip().splitlines()[0]))
            elif len(got) != length:
                bad.append("%-22s is %d bytes, the table says %d"
                           % (body, len(got), length))
        self.assertEqual(bad, [], "\n" + "\n".join(bad))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def tass(self, source, origin=ORIGIN):
        src = os.path.join(self.dir, "s.asm")
        out = os.path.join(self.dir, "s.bin")
        if os.path.exists(out):
            os.unlink(out)
        with open(src, "w") as fh:
            fh.write("* = $%04X\n" % origin + to_tass(source))
        r = subprocess.run([TASS, "--mw65c02", "-q", "-b", "-o", out, src],
                           capture_output=True)
        if r.returncode != 0:
            return None, r.stderr.decode()
        with open(out, "rb") as fh:
            return fh.read(), None

    def check(self, origin):
        rng = random.Random(SEED + origin)
        checked = 0
        for case in range(CASES):
            source, labels = program(rng, origin)
            if source is None:
                continue

            want, err = self.tass(source, origin)
            if want is None:
                self.fail("64tass rejected a generated program (origin $%04X, "
                          "seed %d, case %d):\n%s\n%s"
                          % (origin, SEED, case, source, err))

            try:
                got = self.xap.assemble(source, origin=origin)
            except Error as e:
                self.fail("xap failed with $%02X (origin $%04X, seed %d, "
                          "case %d):\n%s" % (e.code, origin, SEED, case, source))

            self.assertEqual(
                got, want,
                "origin $%04X, seed %d, case %d:\n%s\nxap    %s\n64tass %s"
                % (origin, SEED, case, source, got.hex(" "), want.hex(" ")))
            checked += 1

        self.assertGreater(checked, CASES // 2,
                           "too many generated programs were discarded")

    def test_random_programs_match_64tass(self):
        """Above the zero page, where every forward reference is absolute."""
        self.check(ORIGIN)

    def test_random_programs_match_64tass_in_zero_page(self):
        """Inside it, where the size of a forward reference has to be
        guessed and the guess sometimes has to be taken back."""
        self.check(ZP_ORIGIN)


if __name__ == "__main__":
    unittest.main()
