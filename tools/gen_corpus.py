#!/usr/bin/env python3
"""Writes a benchmark corpus of 65C02 instructions.

One instruction per line and nothing else -- no labels, no directives, no
comments -- because that is all xap assembles so far, and because a benchmark
should measure the thing being changed rather than the thing around it.

Two corpora, and they answer different questions.

isa_even gives all 212 opcodes the same weight. That is the right way to be
sure nothing is slow: no mnemonic and no addressing mode can hide behind the
ones that happen to be common.

isa_real follows the distribution in corpus/real.json, counted from real code
by tools/scan_isa.py. That is the right way to know how fast xap will feel,
because real code is mostly loads, stores, compares and branches and never
uses eighty of the forms at all.

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


def generate(order, shapes, size, dialect="xap", origin=0x1000):
    """Lines cycling through order until the text is as close to size as it
    can get without going over or splitting a line."""
    out = []
    total = 0
    pc = origin
    i = 0

    while True:
        mnemonic, mode, length = shapes[order[i % len(order)]]

        # Values that vary without changing width. A zero page operand that
        # grew to three digits would be assembled as absolute instead, and a
        # different mode is a different measurement.
        byte = (i * 7 + 0x11) & 0xFF
        word = 0x1000 + ((i * 137) & 0x7FFF)

        pc += length
        line = INDENT + spell(mnemonic, mode, dialect,
                              b=byte, w=word, target=pc) + "\n"

        if total + len(line) > size:
            break
        out.append(line)
        total += len(line)
        i += 1

    return "".join(out), i, pc


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
        weights = {k: counts.get(k, 0) for k in shapes}
        label = "%d forms, weighted by %s" % (
            sum(1 for v in weights.values() if v), data.get("source", "?"))
    else:
        weights = {k: 1 for k in shapes}
        label = "all 212 forms, evenly"

    order = schedule(weights)
    text, lines, end = generate(order, shapes, size, args.dialect)
    with open(args.output, "w") as fh:
        fh.write(text)

    used = len({order[i % len(order)] for i in range(min(lines, len(order)))})
    print("%s: %d bytes, %d lines, %s%s"
          % (args.output, len(text), lines, label,
             "" if args.dialect == "xap" else " [%s dialect]" % args.dialect))
    print("  %d distinct instructions used, object code $1000 to $%04X "
          "(%d bytes)" % (used, end, end - 0x1000))


if __name__ == "__main__":
    main()
