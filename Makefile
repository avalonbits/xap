# xap -- a 65C02 assembler for the Commander X16, written in 65C02 assembly.
#
# Most of what is needed to build and test is committed under toolchain/. Two
# pieces are not, because this repository is public and they are not ours to
# redistribute -- 64tass is GPL-2.0 and rom.bin is someone else's KERNAL build
# -- so run this once after cloning:
#
#   tools/setup-toolchain.sh
#
# It fetches those two and reproduces the rest from pinned versions. The
# committed binaries are Linux x86-64, so on anything else run it anyway.
#
# Any of the four can be pointed elsewhere:
#
#   make test TASS=/usr/bin/64tass PYTHON=python3.12
#   make bench X16EMU=~/src/x16-emulator/build/x16emu

TOOLCHAIN = $(CURDIR)/toolchain

# The committed tool when it is there, otherwise whatever is on PATH -- so
# this still works for someone who would rather use their own.
pick = $(if $(wildcard $(1)),$(1),$(2))

TASS   ?= $(call pick,$(TOOLCHAIN)/bin/64tass,64tass)
X16EMU ?= $(call pick,$(TOOLCHAIN)/bin/x16emu,)
X16ROM ?= $(call pick,$(TOOLCHAIN)/rom/rom.bin,)
PYTHON ?= python3

# py65 lives in the toolchain rather than in a virtualenv, which would record
# absolute paths and not survive being moved or committed.
PYLIB = $(TOOLCHAIN)/pylib

SRCDIR   = src
BUILDDIR = build
TESTDIR  = test

# xap is assembled for $A000, the start of the X16's banked RAM window. Nothing
# in it is position dependent yet; the address only has to be somewhere a test
# can load it.
CODEADDR = A000

# The benchmark corpus: every legal instruction, evenly distributed.
CORPUS_SIZE ?= 128K

# How much of a line to assemble. 4 is the whole assembler; lower values stop
# after a phase so the benchmark can attribute cost by difference.
PROFILE ?= 4

TASSFLAGS = --mw65c02 -q -Wall -D XAP_PROFILE=$(PROFILE)

# The environment every Python entry point wants.
PYENV = TASS=$(TASS) X16EMU=$(X16EMU) X16ROM=$(X16ROM) \
	PYTHONPATH=$(PYLIB):$(TESTDIR)

# "build" would name both this target and the directory, which makes it its
# own prerequisite; the binary is the thing worth naming anyway.
.PHONY: all isa test bench hotspots toolchain clean

all: $(BUILDDIR)/xap.bin $(BUILDDIR)/bench.bin

# Every source, not just the one 64tass is pointed at. Listing only xap.asm
# meant an edit to encode.asm assembled nothing and tested the previous
# binary, which is a failure mode that looks exactly like a passing test.
SOURCES = $(wildcard $(SRCDIR)/*.asm) $(SRCDIR)/isa.inc

# 64tass is fetched rather than committed, so say what to do about it rather
# than letting the shell report a missing command.
.PHONY: need-tass
need-tass:
	@command -v $(TASS) >/dev/null 2>&1 || { \
		echo "64tass not found at '$(TASS)'."; \
		echo "Run tools/setup-toolchain.sh to fetch it, or pass TASS=..."; \
		exit 1; }

$(BUILDDIR)/xap.bin: $(SOURCES) | $(BUILDDIR) need-tass
	$(TASS) $(TASSFLAGS) -b -D CODEADDR=\$$$(CODEADDR) \
		-o $@ -L $(BUILDDIR)/xap.lst -l $(BUILDDIR)/xap.labels \
		$(SRCDIR)/xap.asm

# The emulator driver: xap plus a timing stub, built as one binary so the
# harness can read every address it needs out of the label file.
$(BUILDDIR)/bench.bin: $(SOURCES) $(TESTDIR)/bench.asm | $(BUILDDIR) need-tass
	$(TASS) $(TASSFLAGS) -b -D CODEADDR=\$$$(CODEADDR) \
		-o $@ -L $(BUILDDIR)/bench.lst -l $(BUILDDIR)/bench.labels \
		$(TESTDIR)/bench.asm

# Two corpora. isa_even weights all 212 opcodes alike, so nothing can hide;
# isa_real follows corpus/real.json, counted from real code by scan_isa.py, so
# the number means something about how xap will feel.
CORPORA = $(BUILDDIR)/isa_even.asm $(BUILDDIR)/isa_real.asm

$(BUILDDIR)/isa_even.asm: tools/gen_corpus.py tools/gen_isa.py | $(BUILDDIR)
	TASS=$(TASS) PYTHONPATH=$(PYLIB) $(PYTHON) tools/gen_corpus.py \
		-o $@ --size $(CORPUS_SIZE)

$(BUILDDIR)/isa_real.asm: tools/gen_corpus.py tools/gen_isa.py corpus/real.json | $(BUILDDIR)
	TASS=$(TASS) PYTHONPATH=$(PYLIB) $(PYTHON) tools/gen_corpus.py \
		-o $@ --size $(CORPUS_SIZE) --distribution corpus/real.json

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Rebuilds the instruction table from 64tass. Only needed when the generator
# changes; the committed table is what the build uses, and test_isa.py fails if
# the two have drifted apart.
isa:
	TASS=$(TASS) PYTHONPATH=$(PYLIB) $(PYTHON) tools/gen_isa.py -o $(SRCDIR)/isa.inc

# The corpora are a dependency, not an optional extra: the end to end test
# skips itself without them, and a test that skips is not a test.
test: all $(CORPORA)
	$(PYENV) $(PYTHON) -m unittest discover -s $(TESTDIR) -p 'test_*.py' -v

# Per-routine cycle counts, stepped under py65. No emulator needed.
hotspots: all $(CORPORA)
	$(PYENV) $(PYTHON) $(TESTDIR)/hotspots.py $(BUILDDIR)/isa_real.asm

# Phase by phase cycle costs on the emulator.
bench: all $(CORPORA)
	$(PYENV) MAKE="$(MAKE)" $(PYTHON) $(TESTDIR)/benchmark.py $(CORPORA)

# Rebuilds toolchain/ from pinned upstream sources. Only needed to move a pin
# or to port to another architecture.
toolchain:
	tools/setup-toolchain.sh --force

clean:
	rm -rf $(BUILDDIR)
