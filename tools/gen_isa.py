#!/usr/bin/env python3
"""Generates src/isa.inc -- the W65C02S instruction table xap encodes from.

The table is derived by asking 64tass to assemble every (mnemonic, address
mode) pair and recording the byte it produces. Typing 212 opcodes by hand puts
a wrong byte into any program that uses a mistyped form, and it is the kind of
error that unit tests written from the same typo will not catch. 64tass is
also the differential oracle the test suite compares against, so deriving the
table from it means the table and the oracle cannot disagree about what the
instruction set is.

py65's 65C02 core is consulted as an independent second opinion. It knows 195
of the 212 -- it has no BBRx/BBSx and no STP -- so it cannot confirm the whole
table, but where it has an opinion it has to match.

Usage:  python3 tools/gen_isa.py [--tass PATH] [-o src/isa.inc]
"""

import argparse
import os
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# Address modes
#
# The mode number is the index into an instruction's opcode row, so these are
# an ABI between this generator and the assembler: changing the order changes
# every generated row. Fifteen are used and the sixteenth is spare, which is
# what keeps the validity mask a single 16-bit word.
#
# Implied and accumulator are one mode, not two. No mnemonic has both -- NOP
# takes no operand, ASL takes an optional "A" -- so the distinction cannot
# affect which opcode is chosen, and merging them lets "no operand" be a
# single case in the parser instead of a lookup that has to guess which of the
# two a bare mnemonic meant.
# ---------------------------------------------------------------------------

# The fourth field is the mode to try when the operand does not fit in a byte.
# The parser always produces the narrow form, because until the value is known
# it cannot tell "lda $34" from "lda $1234"; widening is where that is settled.
MODES = [
    ("impacc", "{m}",           1, None),    # nop / asl / asl a (see ACC_FORM)
    ("imm",    "{m} #$12",      2, None),    # lda #$12
    ("zp",     "{m} $34",       2, "abs"),   # lda $34
    ("zpx",    "{m} $34,x",     2, "abx"),   # lda $34,x
    ("zpy",    "{m} $34,y",     2, "aby"),   # ldx $34,y
    ("izp",    "{m} ($34)",     2, "iabs"),  # lda ($34)
    ("izx",    "{m} ($34,x)",   2, "iabx"),  # lda ($34,x)
    ("izy",    "{m} ($34),y",   2, None),    # lda ($34),y -- zero page only
    ("abs",    "{m} $5678",     3, None),    # lda $5678
    ("abx",    "{m} $5678,x",   3, None),    # lda $5678,x
    ("aby",    "{m} $5678,y",   3, None),    # lda $5678,y
    ("iabs",   "{m} ($5678)",   3, None),    # jmp ($5678)
    ("iabx",   "{m} ($5678,x)", 3, None),    # jmp ($5678,x)
    ("rel",    "{m} *",         2, None),    # bcc *
    ("zprel",  None,            3, None),    # bbr0 $34,*  -- probed specially
]

# How each mode is written for xap. These differ from the probe templates in
# two places: xap has no "*" for the program counter yet, so a branch needs a
# literal target, and xap attaches the digit of the Rockwell bit instructions
# to the mnemonic. {target} is filled in by whoever knows the program counter.
XAP_TEMPLATE = {
    "impacc": "{m}",
    "imm":    "{m} #${b:02x}",
    "zp":     "{m} ${b:02x}",
    "zpx":    "{m} ${b:02x},x",
    "zpy":    "{m} ${b:02x},y",
    "izp":    "{m} (${b:02x})",
    "izx":    "{m} (${b:02x},x)",
    "izy":    "{m} (${b:02x}),y",
    "abs":    "{m} ${w:04x}",
    "abx":    "{m} ${w:04x},x",
    "aby":    "{m} ${w:04x},y",
    "iabs":   "{m} (${w:04x})",
    "iabx":   "{m} (${w:04x},x)",
    "rel":    "{m} ${target:04x}",
    "zprel":  "{m} ${b:02x},${target:04x}",
}

MODE_INDEX = {name: i for i, (name, _, _, _) in enumerate(MODES)}
MODE_COUNT = 16          # 15 used + 1 spare, so the mask is one word

# Every probe template uses literals, never a symbol. An undefined symbol is a
# forward reference to 64tass, not an error, so a template containing one would
# quietly assemble as absolute and record a mode the mnemonic does not have.

# ---------------------------------------------------------------------------
# Mnemonics
#
# The list only says what to probe; 64tass decides which (mnemonic, mode) pairs
# are real, and the opcode-count check at the end is what actually proves the
# list was complete. A missing mnemonic shows up there as a short count rather
# than as a silently smaller table.
# ---------------------------------------------------------------------------

BASE = """
    adc and asl bcc bcs beq bit bmi bne bpl brk bvc bvs clc cld cli clv cmp
    cpx cpy dec dex dey eor inc inx iny jmp jsr lda ldx ldy lsr nop ora pha
    php pla plp rol ror rti rts sbc sec sed sei sta stx sty tax tay tsx txa
    txs tya
    bra phx phy plx ply stz trb tsb
    stp wai
""".split()

# The Rockwell bit instructions. xap spells them with the digit joined to the
# mnemonic -- RMB3 $34, BBR3 $34,label -- which is the WDC datasheet's form and
# the one cc65, ca65 and py65 use. 64tass is the outlier, taking the bit as a
# first operand, so the probe has to be written its way and the name recorded
# as xap's.
BITOPS = {"rmb": "zp", "smb": "zp", "bbr": "zprel", "bbs": "zprel"}

# Two mnemonics where 64tass assembles more than the documented instruction
# set, and xap should not follow it.
#
#   brk #$12  ->  00 12   BRK with a signature byte. The same opcode as plain
#                         BRK, so it would be the only mnemonic whose mode does
#                         not determine its opcode.
#   nop #$12  ->  82 12   The W65C02S's reserved single- and multi-byte NOPs.
#   nop $34   ->  44 34   $82 and $44 are "reserved for future expansion", not
#                         instructions, and py65 disassembles both as ???.
#
# Restricting these two to implied is also what the ROM assembler does, which
# is the compatibility target.
IMPLIED_ONLY = {"brk", "nop"}

# The six instructions that operate on A as a destination, and so are written
# either bare or with an explicit "A". 64tass wants a bare ASL but insists on
# "inc a", so both spellings have to be probed to reach all six opcodes.
#
# The set is named rather than discovered because "{m} a" is not a safe probe
# to run against every mnemonic: 64tass reads "ldx a" as TAX and "ldy a" as
# TAY, which would record a one-byte accumulator LDX whose opcode belongs to
# another instruction.
ACC_FORM = {"asl", "lsr", "rol", "ror", "inc", "dec"}


def pack(mnemonic):
    """Packs three letters into 15 bits, five bits each, A=1..Z=26.

    This is the lookup key. Comparing two of these is one 16-bit compare, where
    comparing the spelling is a loop over three bytes with a case fold in it --
    and the key is built once while the mnemonic is being read anyway. The
    trailing digit of RMB3/BBR3 is not part of it; those four families share a
    key and are separated by the digit afterwards.
    """
    v = 0
    for ch in mnemonic[:3].lower():
        v = (v << 5) | (ord(ch) - ord('a') + 1)

    return v


class Tass:
    """Assembles one line and reports the bytes, or None if it is not legal."""

    def __init__(self, path):
        self.path = path
        self.dir = tempfile.mkdtemp(prefix="xap_isa_")
        self.src = os.path.join(self.dir, "probe.asm")
        self.out = os.path.join(self.dir, "probe.bin")

    def encode(self, line):
        with open(self.src, "w") as fh:
            fh.write("* = $1000\n    %s\n" % line)
        if os.path.exists(self.out):
            os.unlink(self.out)
        r = subprocess.run(
            [self.path, "--mw65c02", "-q", "-b", "-o", self.out, self.src],
            capture_output=True)
        if r.returncode != 0 or not os.path.exists(self.out):
            return None

        with open(self.out, "rb") as fh:
            return fh.read()


def probe(tass):
    """Returns {MNEMONIC: {mode_index: opcode}} for the whole instruction set."""
    table = {}

    for m in BASE:
        row = {}
        for name, template, length, _ in MODES:
            if template is None:
                continue
            if m in IMPLIED_ONLY and name != "impacc":
                continue

            # A mode can have more than one spelling. 64tass takes a bare ASL
            # as the accumulator form but insists on "inc a" for INC, so both
            # have to be tried; xap accepts either for every mnemonic that has
            # the mode, since they are the same instruction.
            #
            # A result of the wrong length is not the mode asked for. A mode
            # the mnemonic does not have is not always an error: given
            # "adc $34,y", 64tass promotes the operand and assembles
            # absolute,Y instead. Promotion always lengthens the instruction --
            # zero page is two bytes and absolute is three -- so the length is
            # what separates the mode from its promoted form.
            forms = [template]
            if name == "impacc" and m in ACC_FORM:
                forms.append("{m} a")

            code = None
            for form in forms:
                got = tass.encode(form.format(m=m))
                if got is None or len(got) != length:
                    continue
                if code is not None and got != code:
                    sys.exit("%s: spellings of %s disagree, %s vs %s"
                             % (m, name, code.hex(), got.hex()))
                code = got
            if code is None:
                continue
            row[MODE_INDEX[name]] = code[0]
        if not row:
            sys.exit("%s assembled in no addressing mode at all" % m)

        # A branch takes an address, so every probe that supplies one matches
        # it: "bcc $34" is a relative branch to $34, not a zero page BCC, and
        # it is two bytes either way so the length check cannot tell. Relative
        # is exclusive on this CPU -- the nine branches have no other mode, and
        # nothing else has relative -- so finding it settles the row.
        if MODE_INDEX["rel"] in row:
            row = {MODE_INDEX["rel"]: row[MODE_INDEX["rel"]]}
        table[m.upper()] = row

    for stem, mode in BITOPS.items():
        for bit in range(8):
            if mode == "zp":
                line = "%s %d,$34" % (stem, bit)
            else:
                line = "%s %d,$34,*" % (stem, bit)
            code = tass.encode(line)
            if code is None:
                sys.exit("%s%d did not assemble" % (stem, bit))
            table["%s%d" % (stem.upper(), bit)] = {MODE_INDEX[mode]: code[0]}

    return table


def crosscheck(table):
    """Checks the table against py65's 65C02 core where py65 has an opinion."""
    try:
        from py65.devices.mpu65c02 import MPU
    except ImportError:
        print("warning: py65 not installed, skipping cross-check",
              file=sys.stderr)

        return 0

    # py65's mode names for the modes it shares with us.
    theirs = {
        "imp": "impacc", "acc": "impacc", "imm": "imm", "zpg": "zp",
        "zpx": "zpx", "zpy": "zpy", "zpi": "izp", "inx": "izx", "iny": "izy",
        "abs": "abs", "abx": "abx", "aby": "aby", "ind": "iabs", "iax": "iabx",
        "rel": "rel",
    }

    checked = 0
    for opcode, (name, mode) in enumerate(MPU().disassemble):
        if name == "???" or mode not in theirs:
            continue
        want = MODE_INDEX[theirs[mode]]
        got = table.get(name, {})
        if got.get(want) != opcode:
            sys.exit("py65 disagrees: $%02X is %s/%s, we have %r"
                     % (opcode, name, mode, got))
        checked += 1

    return checked


def find_hash(names):
    """Picks how to hash a packed key into the 256-entry lookup table.

    Not a perfect hash: seventy keys collision-free in 256 slots is a one in
    ten thousand shot, and the search for one costs more complexity than it
    saves cycles. Linear probing at a load factor of 0.27 finds a key in about
    1.1 probes, which is close enough to one that the difference is lost in
    the cost of the compare.

    The family searched is (lo ^ (hi << s)) for a small s, because that is
    three instructions on a 6502 and anything cleverer would cost more to
    compute than the probes it saves.
    """
    best = None
    for shift in range(4):
        slots = [0xFF] * 256
        probes = 0
        for slot, name in enumerate(names):
            key = pack(name)
            h = ((key & 0xFF) ^ ((key >> 8) << shift)) & 0xFF
            steps = 1
            while slots[h] != 0xFF:
                h = (h + 1) & 0xFF
                steps += 1
            slots[h] = slot
            probes += steps
        # Insertion order probing and successful-lookup probing are the same
        # walk, so this average is what a lookup will actually cost.
        average = probes / len(names)
        if best is None or average < best[0]:
            best = (average, shift, slots)

    average, shift, slots = best
    assert 0xFF in slots, "the table must keep an empty slot to end a miss on"

    return average, shift, slots


def emit(table, out):
    """Writes the table as 64tass source.

    Three parallel arrays indexed by the same slot number, plus a length table
    indexed by mode. The keys are sorted so the lookup can binary search: 60-odd
    entries is six 16-bit compares, against the linear walk of a linked list of
    variable-length strings that the ROM assembler does for the first token of
    every line.

    The opcode row is a flat 16 bytes rather than a packed list, so selecting an
    opcode is an index and not a population count. It costs about a kilobyte,
    which is worth it while the mode is already in hand; if the ROM bank gets
    tight the rows can be packed against the mask later without the parser
    changing.
    """
    # RMB0..RMB7 and its three sibling families all pack to the same key, which
    # would make the binary search ambiguous. They do not need eight entries
    # each: within a family the opcode is the bit number times sixteen above the
    # first, so one entry and the digit reproduce all eight. The relation is
    # asserted rather than assumed, because it is the kind of regularity that
    # holds until it does not.
    for stem in BITOPS:
        base = table["%s0" % stem.upper()]
        mode, first = next(iter(base.items()))
        for bit in range(8):
            got = table["%s%d" % (stem.upper(), bit)]
            want = first + bit * 0x10
            if got != {mode: want}:
                sys.exit("%s%d is %r, not $%02X in mode %d -- the bit families "
                         "are no longer arithmetic and must be listed in full"
                         % (stem.upper(), bit, got, want, mode))
        for bit in range(1, 8):
            del table["%s%d" % (stem.upper(), bit)]
        table[stem.upper()] = table.pop("%s0" % stem.upper())

    names = sorted(table, key=pack)

    # Every key is now a distinct mnemonic, so any duplicate is a real
    # collision and the search would return whichever it happened to land on.
    for a, b in zip(names, names[1:]):
        if pack(a) == pack(b):
            sys.exit("key collision between %s and %s" % (a, b))

    w = out.write
    w("; GENERATED by tools/gen_isa.py -- do not edit by hand.\n")
    w(";\n")
    w("; The W65C02S instruction set, as 64tass assembles it, cross-checked\n")
    w("; against py65. See the generator for the table layout and why it is\n")
    w("; derived rather than typed.\n")
    w("\n")

    w("XAP_MODE_COUNT = %d\n" % MODE_COUNT)
    for name, _, _, _ in MODES:
        w("XAP_MODE_%-8s = %d\n" % (name.upper(), MODE_INDEX[name]))
    w("XAP_MODE_NONE = $FF\n")
    w("\n")

    w("; Bytes emitted per instruction, indexed by mode.\n")
    w("xapModeLength:\n")
    lengths = [0] * MODE_COUNT
    for name, _, length, _ in MODES:
        lengths[MODE_INDEX[name]] = length
    w("        .byte   %s\n\n" % ",".join(str(n) for n in lengths))

    # The bit-op families need a digit after the mnemonic; everything else must
    # not have one. The flag lets the parser reject "LDA3" and require "RMB3"
    # without a second table of names.
    w("; The wider mode to try when the operand does not fit in a byte,\n")
    w("; XAP_MODE_NONE where there is none.\n")
    w("xapWiden:\n")
    wide = [0xFF] * MODE_COUNT
    for name, _, _, w_name in MODES:
        if w_name is not None:
            wide[MODE_INDEX[name]] = MODE_INDEX[w_name]
    w("        .byte   %s\n\n" % ",".join("$%02x" % b for b in wide))

    w("XAP_FLAG_BITOP = $01            ; RMBn and its three siblings\n")
    w("XAP_FLAG_ACC   = $02            ; a bare A means the accumulator\n\n")

    w("XAP_MNEMONIC_COUNT = %d\n\n" % len(names))

    # Letters to 1..26 and everything else to zero, so reading a letter is one
    # indexed load that both folds the case and rejects a non-letter -- where
    # a compare, a fold and two range checks were about fifteen cycles more,
    # three times a line.
    w("; Character to letter number, 0 if it is not a letter.\n")
    w("xapLetter:\n")
    letters = [0] * 256
    for i in range(26):
        letters[ord('A') + i] = i + 1
        letters[ord('a') + i] = i + 1
    w(wrap(letters))
    w("\n")

    # The key is c1<<10 | c2<<5 | c3. The first letter lands wholly in the
    # high byte as c1<<2 and the third wholly in the low byte, but the second
    # straddles them, so its two halves are looked up rather than shifted out.
    #
    # Indexed by the character, not by the letter number that xapLetter gives.
    # That costs 768 bytes of table and saves ten cycles a mnemonic: the first
    # two letters no longer need a second indexed load to turn the letter
    # number into its contribution, and the "is this a letter" test folds into
    # the same load, because no real contribution has bit 7 set and $80 can
    # therefore mark everything that is not a letter. The third letter's
    # contribution is the letter number itself, so it still reads xapLetter.
    w("; The first letter's whole contribution to the key, c1<<2 in the\n")
    w("; high byte, and $80 for anything that is not a letter.\n")
    w("xapKey1:\n")
    w(wrap([letters[c] << 2 if letters[c] else 0x80 for c in range(256)]))
    w("\n")
    w("; The second letter straddles the halves, so each is tabulated.\n")
    w("; The high half doubles as the letter test, as above.\n")
    w("xapKey2Hi:\n")
    w(wrap([letters[c] >> 3 if letters[c] else 0x80 for c in range(256)]))
    w("xapKey2Lo:\n")
    w(wrap([(letters[c] << 5) & 0xFF for c in range(256)]))
    w("\n")

    # Testing whether a mnemonic has a mode was a loop that shifted the mask
    # right once per mode number -- up to 120 cycles, several times a line.
    # One bit per entry turns that into two ANDs.
    w("; The bit each mode occupies in a mode mask.\n")
    w("xapModeBitLo:\n")
    w(wrap([(1 << m) & 0xFF for m in range(MODE_COUNT)]))
    w("xapModeBitHi:\n")
    w(wrap([(1 << m) >> 8 for m in range(MODE_COUNT)]))
    w("\n")

    # Hex digit value, and decimal by the same table since a decimal digit is
    # just one worth less than ten. Both were subroutines that cost more in
    # call and return than in the compare they did.
    w("; Hex digit value, $FF if it is not one. A decimal digit is an\n")
    w("; entry below ten.\n")
    w("XAP_NOT_DIGIT = $FF\n")
    w("xapHexDigit:\n")
    digits = [0xFF] * 256
    for i in range(10):
        digits[ord('0') + i] = i
    for i in range(6):
        digits[ord('A') + i] = 10 + i
        digits[ord('a') + i] = 10 + i
    w(wrap(digits))
    w("\n")

    # The character classes the line parser asks about, so that "does this end
    # the line" is one load and one AND rather than four compares in a
    # subroutine.
    # Upper cased, but only for a letter or a digit -- anything else comes
    # back zero, which is also how "this ends the name" is said. One load
    # answers both questions, where reading a label used to ask the class
    # table and then call a routine to fold the case, per character.
    w("; Upper case of a character that can appear in a name, 0 otherwise.\n")
    w("xapIdentUpper:\n")
    ident = [0] * 256
    for i in range(26):
        ident[ord('A') + i] = ord('A') + i
        ident[ord('a') + i] = ord('A') + i
    for i in range(10):
        ident[ord('0') + i] = ord('0') + i
    # The ROM assembler's manual: a name is an alphabetic character followed
    # by alphanumerics, underscore, at sign and period. Underscore and at
    # sign can also start one, and a name that starts with either is local.
    for c in "_@.":
        ident[ord(c)] = ord(c)
    w(wrap(ident))
    w("\n")

    w("XAP_CLASS_SPACE = $01           ; space or tab\n")
    w("XAP_CLASS_EOL   = $02           ; NUL, newline, or a comment\n")
    w("XAP_CLASS_IDENT = $04           ; anything a name may contain\n")
    w("xapClass:\n")
    klass = [0] * 256
    for c in (ord(' '), 9):
        klass[c] |= 0x01
    for c in (0, 10, 13, ord(';')):
        klass[c] |= 0x02
    for i in range(26):
        klass[ord('A') + i] |= 0x04
        klass[ord('a') + i] |= 0x04
    for i in range(10):
        klass[ord('0') + i] |= 0x04
    for c in "_@.":
        klass[ord(c)] |= 0x04
    w(wrap(klass))
    w("\n")

    # Pearson hashing for user labels, which unlike mnemonics are not known
    # ahead of time. One xor and one indexed load a character, which is about
    # as cheap as a hash gets on an 8-bit machine, and the result is already
    # the bucket number with nothing to mask.
    #
    # The table is a permutation of 0..255 from a fixed seed, so it is the
    # same table every build. Any permutation works; this one is not special.
    w("; A permutation of 0..255, for hashing label names: h = T[h ^ c].\n")
    w("xapPearson:\n")
    perm = list(range(256))
    state = 0x1234ABCD
    for i in range(255, 0, -1):
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        j = state % (i + 1)
        perm[i], perm[j] = perm[j], perm[i]
    assert sorted(perm) == list(range(256))
    w(wrap(perm))
    w("\n")

    average, shift, slots = find_hash(names)
    w("; Hashed lookup: h = keyLo ^ (keyHi << %d), then probe forward.\n"
      % shift)
    w("; %d mnemonics in 256 slots, %.2f probes for a hit.\n"
      % (len(names), average))
    w("XAP_HASH_SHIFT = %d\n" % shift)
    w("XAP_HASH_EMPTY = $FF\n")

    # The key lives in the hash table, not behind a slot index in it. A probe
    # then reads the key it is comparing against directly, where it used to
    # read a slot number and then index a second pair of tables with it --
    # and that second index needed a register the source cursor was using, so
    # every lookup saved and restored Y around itself.
    #
    # A packed key is fifteen bits, so a high byte with bit 7 set cannot be
    # one and is free to mean an empty slot.
    w("xapHashKeyLo:\n")
    w(wrap([pack(names[i]) & 0xFF if i != 0xFF else 0 for i in slots]))
    w("xapHashKeyHi:\n")
    w(wrap([pack(names[i]) >> 8 if i != 0xFF else 0xFF for i in slots]))
    w("xapHashSlot:\n")
    w(wrap([i if i != 0xFF else 0 for i in slots]))
    w("\n")

    w("; Packed keys, for confirming a hit and rejecting a miss.\n")
    w("xapKeyLo:\n")
    w(wrap([pack(n) & 0xFF for n in names]))
    w("xapKeyHi:\n")
    w(wrap([pack(n) >> 8 for n in names]))
    w("\n")

    w("; Which modes each mnemonic accepts.\n")
    w("xapModeMaskLo:\n")
    masks = [sum(1 << m for m in table[n]) for n in names]
    w(wrap([m & 0xFF for m in masks]))
    w("xapModeMaskHi:\n")
    w(wrap([m >> 8 for m in masks]))
    w("\n")

    # Which mnemonics read a lone "A" as the accumulator rather than as a
    # label of that name. Only the six that have the mode do: "jmp a" is a
    # jump to a label called a, and there is nothing else it could be.
    w("xapMnemonicFlags:\n")
    w(wrap([(1 if n[:3].lower() in BITOPS else 0)
            | (2 if n.lower() in ACC_FORM else 0) for n in names]))
    w("\n")

    w("; The address of each mnemonic's opcode row, so that selecting one is\n")
    w("; two loads rather than shifting the slot number left four.\n")
    w("xapRowLo:\n")
    w("".join("        .byte   %s\n"
              % ",".join("<(xapOpcodes+$%03x)" % (i * MODE_COUNT)
                         for i in range(j, min(j + 8, len(names))))
              for j in range(0, len(names), 8)))
    w("xapRowHi:\n")
    w("".join("        .byte   %s\n"
              % ",".join(">(xapOpcodes+$%03x)" % (i * MODE_COUNT)
                         for i in range(j, min(j + 8, len(names))))
              for j in range(0, len(names), 8)))
    w("\n")

    w("; Opcode by mode, %d bytes per mnemonic, $00 where the mode is not\n"
      % MODE_COUNT)
    w("; legal -- the mask says which, since $00 is BRK. For a mnemonic with\n")
    w("; XAP_FLAG_BITOP the entry is the bit-0 opcode: add the digit times 16.\n")
    w("xapOpcodes:\n")
    for n in names:
        row = [table[n].get(m, 0) for m in range(MODE_COUNT)]
        w("        .byte   %s ; %s\n"
          % (",".join("$%02x" % b for b in row), n))
    w("\n")

    return names


def wrap(values, per=16):
    out = []
    for i in range(0, len(values), per):
        out.append("        .byte   %s\n"
                   % ",".join("$%02x" % v for v in values[i:i + per]))

    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tass", default=os.environ.get("TASS", "64tass"))
    ap.add_argument("-o", "--output", default="src/isa.inc")
    args = ap.parse_args()

    tass = Tass(args.tass)
    if tass.encode("nop") is None:
        sys.exit("cannot run %s -- set --tass or $TASS" % args.tass)

    table = probe(tass)

    # The real completeness check. The W65C02S has 212 defined opcodes; if the
    # mnemonic list above were missing one, or a probe template were wrong, the
    # count comes up short here rather than the table quietly being smaller
    # than the instruction set.
    seen = {}
    for name, row in table.items():
        for mode, opcode in row.items():
            if opcode in seen:
                sys.exit("$%02X produced by both %s and %s"
                         % (opcode, seen[opcode], name))
            seen[opcode] = name
    if len(seen) != 212:
        sys.exit("got %d distinct opcodes, the W65C02S has 212" % len(seen))

    checked = crosscheck(table)

    with open(args.output, "w") as fh:
        names = emit(table, fh)

    print("%s: %d mnemonics, %d opcodes, %d confirmed against py65"
          % (args.output, len(names), len(seen), checked))


if __name__ == "__main__":
    main()
