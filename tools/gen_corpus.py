#!/usr/bin/env python3
"""Writes a benchmark corpus of 65C02 instructions.

One instruction per line, with no labels and no directives, because that is
all xap assembles so far.

isa_real also carries blank lines and comments, in the proportions
corpus/real.json measured from real source: a tenth of lines blank, an eighth
nothing but a comment, and comment text making up nearly a third of all the
characters in the file. xap has always handled comments -- they fall out of
the line framing -- but a corpus without any is not measuring the file anyone
actually assembles.

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
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_isa as g

INDENT = "    "

# Comment text for isa_real. What matters is the length, since a comment is
# scanned character by character and never parsed, but real-looking text keeps
# the corpus readable when something goes wrong and it has to be eyeballed.
# These average about 26 characters, which is what was measured.
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


def generate(order, shapes, size, dialect="xap", layout=None, origin=0x1000):
    """Lines cycling through order until the text is as close to size as it
    can get without going over or splitting a line.

    Blank and comment lines are spread by accumulator rather than at random:
    add the wanted fraction each line and emit one whenever the total passes
    one. That gives the exact proportion, evenly spaced, and the same file
    every time.

    Returns the text, the total line count, how many of those were
    instructions, the end of the program counter, and which forms got used --
    the caller checks that last one, because a schedule longer than the file
    leaves the tail of it unvisited.
    """
    out = []
    used = set()
    total = 0
    pc = origin
    i = 0
    lines = 0

    blank_rate = layout["blank"] if layout else 0.0
    comment_rate = layout["comment_only"] if layout else 0.0
    # The trailing-comment fraction is measured over every line, but only
    # instruction lines can carry one, so it is scaled up by the share of
    # lines that are instructions.
    trailing_rate = 0.0
    if layout:
        instruction_share = 1.0 - layout["blank"] - layout["comment_only"]
        trailing_rate = layout["trailing_comment"] / instruction_share
    blank_acc = comment_acc = trailing_acc = 0.0
    remark = 0

    while True:
        blank_acc += blank_rate
        comment_acc += comment_rate
        if blank_acc >= 1.0:
            blank_acc -= 1.0
            line = "\n"
            if total + len(line) > size:
                break
            out.append(line)
            total += len(line)
            lines += 1
            continue
        if comment_acc >= 1.0:
            comment_acc -= 1.0
            line = INDENT + COMMENTS[remark % len(COMMENTS)] + "\n"
            remark += 1
            if total + len(line) > size:
                break
            out.append(line)
            total += len(line)
            lines += 1
            continue

        key = order[i % len(order)]
        mnemonic, mode, length = shapes[key]

        # Values that vary without changing width. A zero page operand that
        # grew to three digits would be assembled as absolute instead, and a
        # different mode is a different measurement.
        byte = (i * 7 + 0x11) & 0xFF
        word = 0x1000 + ((i * 137) & 0x7FFF)

        pc += length
        line = INDENT + spell(mnemonic, mode, dialect,
                              b=byte, w=word, target=pc)

        trailing_acc += trailing_rate
        if trailing_acc >= 1.0:
            trailing_acc -= 1.0
            line += "  " + COMMENTS[remark % len(COMMENTS)]
            remark += 1
        line += "\n"

        if total + len(line) > size:
            break
        out.append(line)
        used.add(key)
        total += len(line)
        lines += 1
        i += 1

    return "".join(out), lines, i, pc, used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--size", default="128K")
    ap.add_argument("--distribution", default="",
                    help="weights from tools/scan_isa.py; even if omitted")
    ap.add_argument("--dialect", choices=("xap", "64tass"), default="xap")
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

    # The schedule is one entry per weighted occurrence, and the file stops
    # when it is full. If the schedule is longer than the file has lines, its
    # tail is never reached and the rarest forms -- the floored ones -- are
    # exactly what goes missing. So the weights are scaled to the number of
    # lines that will fit, which a trial run measures.
    order = schedule(weights)
    text, lines, instrs, end, used = generate(
        order, shapes, size, args.dialect, layout)

    # Scaled against the instruction lines, not the total: blanks and comments
    # take up room in the file but claim nothing from the schedule.
    if instrs < len(order):
        scale = instrs / len(order)
        weights = {k: max(int(round(w * scale)), 1) for k, w in weights.items()}
        order = schedule(weights)
        text, lines, instrs, end, used = generate(
            order, shapes, size, args.dialect, layout)

    missing = set(shapes) - used
    if missing:
        sys.exit("%d instructions did not make it into the corpus: %s"
                 % (len(missing), ", ".join(sorted(missing)[:6])))

    with open(args.output, "w") as fh:
        fh.write(text)

    print("%s: %d bytes, %d lines, %s%s"
          % (args.output, len(text), lines, label,
             "" if args.dialect == "xap" else " [%s dialect]" % args.dialect))
    print("  all %d instructions present, object code $1000 to $%04X "
          "(%d bytes)" % (len(used), end, end - 0x1000))
    if layout:
        print("  %d instruction lines, %d blank or comment"
              % (instrs, lines - instrs))


if __name__ == "__main__":
    main()
