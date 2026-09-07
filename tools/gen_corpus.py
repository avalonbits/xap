#!/usr/bin/env python3
"""Writes a benchmark corpus of 65C02 instructions.

One instruction per line, with no labels and no directives, because that is
all xap assembles so far.

isa_real also carries blank lines and comments, in the proportions
corpus/real.json measured from real source: a tenth of lines blank, an eighth
nothing but a comment, and comment text making up nearly a third of all the
characters in the file.

Both carry labels, defined and referenced in both directions. Real source
defines a label on 4.4% of its lines and gives 54% of its instructions a name
rather than a number for an operand, so a corpus without any says nothing
about the symbol table, the hash, or the fixups -- which is most of what an
assembler does once it has labels at all.

isa_jump_degenerate is the other end of that: every label is referenced before
any of them is defined, and they are then defined in reverse, so the peak
number of outstanding fixups is as large as the file can make it. It is a
stress test rather than a throughput measure and is sized by what the heaps
hold, not by a byte count.

Two corpora, and they answer different questions.

isa_even gives all 212 opcodes the same weight. That is the right way to be
sure nothing is slow: no mnemonic and no addressing mode can hide behind the
ones that happen to be common.

isa_real follows the distribution in corpus/real.json, counted from real code
by tools/scan_isa.py. That is the right way to know how fast xap will feel,
because real code is mostly loads, stores, compares and branches. It still
carries every one of the 212 at least once: real code never uses eighty of
them, but a corpus that leaves them out stops being able to catch a
regression in them, and one line each costs half a percent of the file.

Whichever weights are used, the forms are interleaved by position rather than
emitted in runs, so any prefix of the file has the same mix as the whole. The
hotspot profiler reads a prefix, and a prefix that was all one instruction
would profile that instruction.

Operand values change from line to line, but their width does not: a zero page
mode always gets two hex digits and an absolute mode four, because the number
of digits decides how much work the parser does and which mode gets chosen.
Branch targets point at the instruction after the branch, which needs the
program counter, so the generator tracks it.

    python3 tools/gen_corpus.py -o build/isa_even.asm --size 128K
    python3 tools/gen_corpus.py -o build/isa_real.asm --size 128K \\
        --distribution corpus/real.json
"""

import argparse
import json
import random
import re
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_isa as g

INDENT = "    "

# The modes whose operand can be a code label. The rest need a value in zero
# page or an immediate, and until assignments exist there is no way to give a
# name to one of those.
LABEL_CAPABLE = {"abs", "abx", "aby", "iabs", "iabx", "rel", "zprel"}

# Measured over 80931 lines of x16-rom and SlithyMatt's tutorial: 4.4% of
# lines define a label, and 54% of instructions take a name rather than a
# number for an operand.
#
# The definition rate is reproduced exactly. The reference rate cannot be:
# over half of real code's named operands are constants -- hardware
# registers, sizes, character codes -- reached through immediate and zero
# page modes, and until assignments exist there is no way to give a name to
# one of those. Only about a third of instructions have a mode that can take
# a code label at all, so nine in ten of those is as close as this gets. The
# generator reports what it actually reached.
LABEL_DEFINITION_RATE = 0.044
LABEL_REFERENCE_RATE = 0.9

# How far a reference reaches, in bytes of object code. Real code mostly
# calls nearby and loops locally; this keeps the number of holes held open at
# once in the same range that real source produces.
LABEL_REACH = 1024

# Comment text for isa_real. What matters is the length, since a comment is
# scanned character by character and never parsed, but real-looking text keeps
# the corpus readable when something goes wrong and it has to be eyeballed.
# These average about 26 characters, which is what was measured.
# How a reference is written, per mode. The operand is a name, so there is no
# width to choose and nothing to format but the target.
LABEL_TEMPLATE = {
    "abs":   "{m} {target}",
    "abx":   "{m} {target},x",
    "aby":   "{m} {target},y",
    "iabs":  "{m} ({target})",
    "iabx":  "{m} ({target},x)",
    "rel":   "{m} {target}",
    "zprel": "{m} ${b:02x},{target}",
}

COMMENTS = [
    "; set up the pointer",
    "; fall through on purpose",
    "; carry is clear here",
    "; save it for the caller",
    "; the loop counter",
    "; not reached in bank 0",
    "; preserve X across this",
    "; high byte first",
    "; wraps at the page boundary",
    "; kernal clobbers Y",
    "; assumes the port is open",
    "; one past the end",
    "; restore the bank we came from",
    "; this costs four cycles",
    "; see the note in the header",
    "; must stay in zero page",
]


def forms(tass):
    """Every legal instruction, as {"MNEMONIC/mode": (mnemonic, mode, length)}."""
    table = g.probe(tass)
    names = {v: k for k, v in g.MODE_INDEX.items()}
    lengths = {name: length for name, _, length, _ in g.MODES}

    out = {}
    for name in sorted(table):
        for index in sorted(table[name]):
            mode = names[index]
            out["%s/%s" % (name, mode)] = (name.lower(), mode, lengths[mode])

    return out


def schedule(weights):
    """Orders the forms so that each appears at its own even spacing.

    The k-th of n occurrences of a form belongs at (k + 0.5) / n of the way
    through, so sorting every occurrence by that position interleaves them all
    in proportion. A form with twice the weight simply has twice as many
    positions to claim.
    """
    events = []
    for key, weight in weights.items():
        if weight <= 0:
            continue
        for k in range(weight):
            events.append(((k + 0.5) / weight, key))
    events.sort()

    return [key for _, key in events]


def spell(mnemonic, mode, dialect, **operands):
    """One instruction, written the way the given assembler wants it.

    Only two things differ between xap and 64tass. The accumulator form is
    written with an explicit A, which both accept -- 64tass insists on it for
    INC and DEC -- so that side is settled by always writing it. The Rockwell
    bit instructions have no common spelling: xap attaches the digit to the
    mnemonic, as cc65 and the WDC datasheet do, and 64tass takes it as a first
    operand.
    """
    text = g.XAP_TEMPLATE[mode].format(m=mnemonic, **operands)

    if mode == "impacc" and mnemonic in g.ACC_FORM:
        return text + " a"

    if dialect == "64tass" and mnemonic[:3] in g.BITOPS:
        stem, digit = mnemonic[:3], mnemonic[3]
        rest = text.split(None, 1)[1]

        return "%s %s,%s" % (stem, digit, rest)

    return text


def build(order, shapes, count, layout, origin, rng):
    """Lays out `count` lines and returns them as text, with what was used.

    Two passes. The first fixes what each line is, and so how long it is, and
    so where every label lands. The second chooses which label each reference
    names, which cannot be done until the addresses are known -- a branch has
    to be able to reach its target.
    """
    blank_rate = layout["blank"] if layout else 0.0
    comment_rate = layout["comment_only"] if layout else 0.0
    trailing_rate = 0.0
    if layout:
        share = 1.0 - blank_rate - comment_rate
        trailing_rate = layout["trailing_comment"] / share

    items = []
    blank_acc = comment_acc = trailing_acc = label_acc = 0.0
    remark = 0
    i = 0

    while len(items) < count:
        blank_acc += blank_rate
        comment_acc += comment_rate
        label_acc += LABEL_DEFINITION_RATE

        if blank_acc >= 1.0:
            blank_acc -= 1.0
            items.append({"kind": "blank"})
            continue
        if comment_acc >= 1.0:
            comment_acc -= 1.0
            items.append({"kind": "comment",
                          "text": COMMENTS[remark % len(COMMENTS)]})
            remark += 1
            continue
        if label_acc >= 1.0:
            label_acc -= 1.0
            items.append({"kind": "label"})
            continue

        key = order[i % len(order)]
        mnemonic, mode, length = shapes[key]
        trailing_acc += trailing_rate
        note = None
        if trailing_acc >= 1.0:
            trailing_acc -= 1.0
            note = COMMENTS[remark % len(COMMENTS)]
            remark += 1
        items.append({"kind": "insn", "key": key, "mnemonic": mnemonic,
                      "mode": mode, "length": length, "note": note,
                      "index": i})
        i += 1

    # Where everything lands, and so where every label is.
    pc = origin
    labels = []
    for n, item in enumerate(items):
        item["pc"] = pc
        if item["kind"] == "label":
            item["name"] = "L%d" % len(labels)
            labels.append((item["name"], pc))
        pc += item.get("length", 0)

    # Which label each reference names. Half look back and half look forward,
    # so that both the already-defined path and the fixup path are exercised;
    # a branch is only given a target it can actually reach.
    #
    # References are kept local. Real code calls the routine next door and
    # branches within a loop far more often than it reaches across the whole
    # file, and a forward reference is held as a hole until its label turns
    # up -- so picking targets uniformly would hold hundreds of them at once
    # and say more about the fixup heap than about the assembler.
    # isa_jump_degenerate is where that worst case belongs, deliberately.
    reference_acc = 0.0
    out = []
    used = set()
    for n, item in enumerate(items):
        kind = item["kind"]
        if kind == "blank":
            out.append("")
            continue
        if kind == "comment":
            out.append(INDENT + item["text"])
            continue
        if kind == "label":
            out.append("%s:" % item["name"])
            continue

        used.add(item["key"])
        mode = item["mode"]
        target = None
        if mode in LABEL_CAPABLE and labels:
            reference_acc += LABEL_REFERENCE_RATE
            if reference_acc >= 1.0:
                reference_acc -= 1.0
                here = item["pc"]
                if mode in ("rel", "zprel"):
                    reach = [nm for nm, at in labels
                             if -128 <= at - (here + item["length"]) <= 127]
                else:
                    reach = [nm for nm, at in labels
                             if abs(at - here) <= LABEL_REACH]
                if reach:
                    # Alternate which direction is preferred, so neither the
                    # settled path nor the fixup path is the only one taken.
                    back = [nm for nm in reach
                            if dict(labels)[nm] <= here]
                    fwd = [nm for nm in reach if dict(labels)[nm] > here]
                    pool = (back or fwd) if (n & 1) else (fwd or back)
                    target = rng.choice(pool)

        b = (item["index"] * 7 + 0x11) & 0xFF
        w = 0x1000 + ((item["index"] * 137) & 0x7FFF)
        if target is not None:
            body = LABEL_TEMPLATE[mode].format(m=item["mnemonic"], b=b,
                                               target=target)
        else:
            body = spell(item["mnemonic"], mode, "xap", b=b, w=w,
                         target=item["pc"] + item["length"])
        line = INDENT + body
        if item["note"]:
            line += "  " + item["note"]
        out.append(line)

    instrs = sum(1 for it in items if it["kind"] == "insn")

    return "\n".join(out) + "\n", used, len(labels), pc, instrs


def degenerate(shapes, count, origin=0x1000):
    """Every label referenced before any is defined, then defined backwards.

    The worst case the fixup table can be asked for: nothing can be resolved
    until the definitions start, so the number of holes held at once is the
    number of labels. Defining them in reverse means the last reference made
    is the first one retired.
    """
    lines = ["    jmp L%d" % i for i in range(count)]
    lines += ["L%d:" % i for i in range(count - 1, -1, -1)]

    return "\n".join(lines) + "\n", count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--size", default="128K")
    ap.add_argument("--distribution", default="",
                    help="weights from tools/scan_isa.py; even if omitted")
    ap.add_argument("--degenerate", type=int, default=0, metavar="N",
                    help="instead, N labels all used before any is defined")
    ap.add_argument("--tass", default=os.environ.get("TASS", "64tass"))
    args = ap.parse_args()

    size = args.size.upper()
    for suffix, scale in (("K", 1024), ("M", 1024 * 1024)):
        if size.endswith(suffix):
            size = int(size[:-1]) * scale
            break
    else:
        size = int(size)

    tass = g.Tass(args.tass)
    if tass.encode("nop") is None:
        sys.exit("cannot run %s -- set --tass or $TASS" % args.tass)

    shapes = forms(tass)
    if len(shapes) != 212:
        sys.exit("got %d instructions, the W65C02S has 212" % len(shapes))

    if args.degenerate:
        text, labels = degenerate(shapes, args.degenerate)
        with open(args.output, "w") as fh:
            fh.write(text)
        print("%s: %d bytes, %d lines, %d labels all referenced before any "
              "is defined" % (args.output, len(text), text.count("\n"), labels))
        print("  and defined in reverse, so every hole is open at once")

        return

    if args.distribution:
        with open(args.distribution) as fh:
            data = json.load(fh)
        counts = data["counts"]
        unknown = set(counts) - set(shapes)
        if unknown:
            sys.exit("distribution names forms that do not exist: %s"
                     % ", ".join(sorted(unknown)[:5]))
        # Floored at one. Every instruction has to appear, or the corpus
        # cannot catch a regression in the eighty forms real code never uses.
        weights = {k: max(counts.get(k, 0), 1) for k in shapes}
        seen = sum(1 for k in shapes if counts.get(k))
        layout = data.get("shape")
        label = ("%d forms as they appear in real code, %d more once each"
                 % (seen, len(shapes) - seen))
    else:
        weights = {k: 1 for k in shapes}
        layout = None
        label = "all 212 forms, evenly"

    # The line count that fills the file is not known ahead of time, because
    # a line's length depends on what it turned out to be. Closing in on it
    # is cheaper than guessing, and the result is the same every run.
    def attempt(order, count):
        rng = random.Random(0x5A5A)

        return build(order, shapes, count, layout, 0x1000, rng)

    order = schedule(weights)
    count = max(len(order), size // 20)
    text = ""
    for _ in range(12):
        text, used, labels, end, instrs = attempt(order, count)
        if len(text) > size:
            count = int(count * size / len(text))
        elif len(text) > size * 0.995:
            break
        else:
            count = int(count * size / len(text)) + 1

    while len(text) > size:                 # trim back to fit exactly
        count -= 1
        text, used, labels, end, instrs = attempt(order, count)

    # The schedule is one entry per weighted occurrence, and only instruction
    # lines draw from it -- blanks, comments and label definitions do not. So
    # a schedule longer than the file has instructions leaves its tail
    # unvisited, and the tail is the rarest forms. Scale to what fits and try
    # again.
    if instrs < len(order):
        scale = instrs / len(order)
        weights = {k: max(int(round(w * scale)), 1) for k, w in weights.items()}
        order = schedule(weights)
        text, used, labels, end, instrs = attempt(order, count)
        while len(text) > size:
            count -= 1
            text, used, labels, end, instrs = attempt(order, count)

    missing = set(shapes) - used
    if missing:
        sys.exit("%d instructions did not make it into the corpus: %s"
                 % (len(missing), ", ".join(sorted(missing)[:6])))

    with open(args.output, "w") as fh:
        fh.write(text)

    lines = text.count("\n")
    named = sum(1 for l in text.splitlines()
                if l.startswith(INDENT) and not l.strip().startswith(";")
                and re.search(r"\bL\d+\b", l))
    print("%s: %d bytes, %d lines, %s"
          % (args.output, len(text), lines, label))
    print("  all %d instructions present, %d labels on %.1f%% of lines, "
          "%.0f%% of instructions take a name"
          % (len(used), labels, 100.0 * labels / lines,
             100.0 * named / max(instrs, 1)))
    print("  object code $1000 to $%04X" % end)


if __name__ == "__main__":
    main()
