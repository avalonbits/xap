#!/usr/bin/env python3
"""Counts which instructions real 6502 code actually uses.

The even corpus gives every instruction the same weight, which is the right
way to be sure nothing is slow and the wrong way to know how fast xap will
feel. Real code is mostly loads, stores, compares and branches, and barely
touches whole addressing modes. This reads assembler listings and counts what
is really there, so a second corpus can be built to match.

Listings rather than sources, because the addressing mode of "lda foo" depends
on where foo turned out to be, and only the assembler knows that. Every
assembler worth using can emit one, and the formats are close enough that a
single pattern reads all of them: an address, then the bytes emitted, then the
source line.

An emitted byte is only counted when it is a legal opcode *and* the source
line's first word is the mnemonic that opcode belongs to. Data bytes look like
opcodes often enough to matter, and that check throws them out.

The shape of the lines is counted too -- how many are blank, how many are
nothing but a comment, how often a comment trails an instruction, and how long
they run. Nearly a third of real 6502 source is comment text, and a corpus
without any is not measuring the file anyone actually assembles.

    python3 tools/scan_isa.py -o dist.json build/lst/*.lst
"""

import argparse
import collections
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_isa as g

# ca65:   000000r 1  A6 04        	ldx r1L
# 64tass: .1000  a9 12           lda #$12
# acme:   1000  A9 12            lda #$12
#
# All three are an address, optional bookkeeping, a run of hex byte pairs, then
# the source. The bytes are what matter and the source is only needed to
# confirm the mnemonic.
LINE = re.compile(
    r"^\s*[.$]?[0-9A-Fa-f]{4,6}r?\s+"      # address
    r"(?:\d+\s+)?"                          # ca65's include depth
    r"((?:[0-9A-Fa-f]{2}\s)+)"              # the emitted bytes
    r"\s*(\S.*)?$")                         # the source line, if any

# A label, then the mnemonic. Anything else on the line is the operand.
SOURCE = re.compile(r"^\s*(?:[A-Za-z_@.][\w@.]*:\s*)?([A-Za-z]{3}[0-7]?)\b")


def opcode_map(tass):
    """opcode -> (mnemonic, mode name), which is a bijection over the 212."""
    table = g.probe(tass)
    modes = {v: k for k, v in g.MODE_INDEX.items()}

    out = {}
    for name, row in table.items():
        for index, opcode in row.items():
            out[opcode] = (name.upper(), modes[index])

    return out


def shape(paths):
    """How real source lines are laid out, not what they assemble to.

    Read from the original sources rather than the listings, because layout is
    a purely syntactic question that needs no assembler -- and because a
    listing pads every line with its address and byte columns, which are not
    part of anybody's source.

    A semicolon only starts a comment outside quotes -- "lda #';'" is a
    character literal -- so the scan tracks them, exactly as the assembler
    has to.
    """
    lines = blank = comment_only = trailing = 0
    comment_chars = total_chars = 0

    for path in paths:
        with open(path, errors="replace") as fh:
            for raw in fh:
                source = raw.rstrip("\n")
                lines += 1
                total_chars += len(source) + 1

                stripped = source.strip()
                if not stripped:
                    blank += 1
                    continue

                quote = None
                start = None
                for i, ch in enumerate(source):
                    if quote:
                        if ch == quote:
                            quote = None
                    elif ch in "\"'":
                        quote = ch
                    elif ch == ";":
                        start = i
                        break
                if start is None:
                    continue

                comment_chars += len(source) - start + 1
                if stripped.startswith(";"):
                    comment_only += 1
                else:
                    trailing += 1

    commented = comment_only + trailing

    return {
        "lines": lines,
        "blank": round(blank / lines, 4),
        "comment_only": round(comment_only / lines, 4),
        "trailing_comment": round(trailing / lines, 4),
        "comment_chars": round(comment_chars / total_chars, 4),
        "mean_comment_length": round(comment_chars / commented, 1) if commented else 0,
    }


def scan(paths, opcodes):
    counts = collections.Counter()
    lines = 0
    skipped = 0

    for path in paths:
        with open(path, errors="replace") as fh:
            for line in fh:
                m = LINE.match(line.rstrip("\n"))
                if not m:
                    continue
                source = m.group(2) or ""
                s = SOURCE.match(source)
                if not s:
                    continue

                first = int(m.group(1).split()[0], 16)
                if first not in opcodes:
                    continue

                mnemonic, mode = opcodes[first]
                lines += 1

                # The word in the source has to be the instruction that byte
                # encodes. A table of data whose first byte happens to be $A9
                # is not an LDA.
                if s.group(1).upper() != mnemonic:
                    skipped += 1
                    continue

                counts["%s/%s" % (mnemonic, mode)] += 1

    return counts, lines, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("listings", nargs="+")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--sources", nargs="*", default=[],
                    help="original source files, for the line shape")
    ap.add_argument("--tass", default=os.environ.get("TASS", "64tass"))
    ap.add_argument("--source", default="", help="what this was scanned from")
    args = ap.parse_args()

    tass = g.Tass(args.tass)
    if tass.encode("nop") is None:
        sys.exit("cannot run %s -- set --tass or $TASS" % args.tass)

    opcodes = opcode_map(tass)
    counts, lines, skipped = scan(args.listings, opcodes)
    layout = shape(args.sources) if args.sources else None

    if not counts:
        sys.exit("no instructions found -- is the listing format recognised?")

    total = sum(counts.values())
    with open(args.output, "w") as fh:
        json.dump({
            "source": args.source,
            "listings": len(args.listings),
            "instructions": total,
            "forms": len(counts),
            "shape": layout,
            "counts": dict(sorted(counts.items())),
        }, fh, indent=1, sort_keys=False)
        fh.write("\n")

    print("%s: %d instructions over %d of the 212 forms, from %d listings"
          % (args.output, total, len(counts), len(args.listings)))
    print("  %d candidate lines rejected as data" % skipped)
    print("\n  the twelve most common:")
    for form, n in counts.most_common(12):
        print("    %-16s %7d  %5.2f%%" % (form, n, 100.0 * n / total))

    missing = 212 - len(counts)
    if missing:
        print("\n  %d forms never appear at all" % missing)

    if not layout:
        return
    print("\n  line shape over %d lines:" % layout["lines"])
    print("    %5.1f%% blank" % (100 * layout["blank"]))
    print("    %5.1f%% nothing but a comment" % (100 * layout["comment_only"]))
    print("    %5.1f%% a comment after something else"
          % (100 * layout["trailing_comment"]))
    print("    %5.1f%% of all characters are comment text, mean length %.0f"
          % (100 * layout["comment_chars"], layout["mean_comment_length"]))


if __name__ == "__main__":
    main()
