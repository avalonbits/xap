# xap -- a 65C02 assembler for the Commander X16, written in 65C02 assembly.
#
# Two host tools are needed, neither of them vendored:
#
#   64tass   builds xap, and is the oracle the tests compare its output
#            against.  apt install 64tass
#   py65     runs xap's own code on the host, so the tests need no emulator.
#            pip install py65
#
# Both can be pointed elsewhere:  make test TASS=/path/to/64tass PYTHON=...

TASS   ?= 64tass
PYTHON ?= python3

SRCDIR   = src
BUILDDIR = build
TESTDIR  = test

# xap is assembled for $A000, the start of the X16's banked RAM window. Nothing
# in it is position dependent yet; the address only has to be somewhere a test
# can load it.
CODEADDR = A000

TASSFLAGS = --mw65c02 -q -Wall

# "build" would name both this target and the directory, which makes it its
# own prerequisite; the binary is the thing worth naming anyway.
.PHONY: all isa test clean

all: $(BUILDDIR)/xap.bin

# Every source, not just the one 64tass is pointed at. Listing only xap.asm
# meant an edit to encode.asm assembled nothing and tested the previous
# binary, which is a failure mode that looks exactly like a passing test.
SOURCES = $(wildcard $(SRCDIR)/*.asm) $(SRCDIR)/isa.inc

$(BUILDDIR)/xap.bin: $(SOURCES) | $(BUILDDIR)
	$(TASS) $(TASSFLAGS) -b -D CODEADDR=\$$$(CODEADDR) \
		-o $@ -L $(BUILDDIR)/xap.lst -l $(BUILDDIR)/xap.labels \
		$(SRCDIR)/xap.asm

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Rebuilds the instruction table from 64tass. Only needed when the generator
# changes; the committed table is what the build uses, and test_isa.py fails if
# the two have drifted apart.
isa:
	TASS=$(TASS) $(PYTHON) tools/gen_isa.py -o $(SRCDIR)/isa.inc

test: all
	TASS=$(TASS) $(PYTHON) -m unittest discover -s $(TESTDIR) -p 'test_*.py' -v

clean:
	rm -rf $(BUILDDIR)
