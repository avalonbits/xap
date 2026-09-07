#!/bin/bash
# Provisions everything xap is built and tested with into toolchain/.
#
# The built artefacts are committed, so a clone has a working build and test
# loop with no network and nothing to install. This script is what produced
# them and what reproduces them: run it to rebuild, upgrade a pin, or port the
# toolchain to another machine, since the committed binaries are Linux x86-64.
#
#   tools/setup-toolchain.sh            # fill in whatever is missing
#   tools/setup-toolchain.sh --force    # rebuild everything
#
# Needs, only when actually building something: apt-get, pip, cmake, a C
# compiler and the SDL2 development headers.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TOOLS="$ROOT/toolchain"

# Pinned so that a rebuild produces what is committed rather than whatever is
# current. Moving a pin is a deliberate act with its own commit.
TASS_VERSION="1.59.3120-2"
EMU_COMMIT="77f2bab"
EMU_REPO="https://github.com/X16Community/x16-emulator.git"
ROM_REPO="https://github.com/PeteGollan/X16_Assembler_in_ROM.git"
ROM_FILE="r49_ti.bin"
PY65_VERSION="1.2.0"

FORCE=""
[ "${1:-}" = "--force" ] && FORCE=1

have() { [ -z "$FORCE" ] && [ -e "$1" ]; }

mkdir -p "$TOOLS/bin" "$TOOLS/rom" "$TOOLS/pylib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 64tass -- builds xap, and is the oracle its output is compared against.
# ---------------------------------------------------------------------------

if have "$TOOLS/bin/64tass"; then
    echo "64tass: already present"
else
    echo "64tass: fetching $TASS_VERSION"
    (cd "$WORK" && apt-get download "64tass=$TASS_VERSION" >/dev/null)
    dpkg-deb -x "$WORK"/64tass_*.deb "$WORK/tass"
    cp "$WORK/tass/usr/bin/64tass" "$TOOLS/bin/"
    chmod +x "$TOOLS/bin/64tass"
fi

# ---------------------------------------------------------------------------
# py65 -- runs xap's own 65C02 code on the host, so the encoding tests need no
# emulator. Installed to a directory rather than a virtualenv because a
# virtualenv records absolute paths and does not survive being moved.
# ---------------------------------------------------------------------------

if have "$TOOLS/pylib/py65"; then
    echo "py65: already present"
else
    echo "py65: installing $PY65_VERSION"
    pip install --quiet --target "$TOOLS/pylib" --upgrade \
        "py65==$PY65_VERSION" >/dev/null
    # Nothing here is run as a program, py65's own test suite is not ours to
    # run, and the metadata is noise in a diff.
    rm -rf "$TOOLS/pylib"/*.dist-info "$TOOLS/pylib"/bin \
           "$TOOLS/pylib/py65/tests" "$TOOLS/pylib/py65/monitor.py"
    find "$TOOLS/pylib" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# x16emu -- the real machine. Needed for the file I/O tests and for every
# cycle count, and there is no packaged build of it to depend on.
# ---------------------------------------------------------------------------

if have "$TOOLS/bin/x16emu"; then
    echo "x16emu: already present"
else
    echo "x16emu: building $EMU_COMMIT"
    git clone --quiet "$EMU_REPO" "$WORK/emu"
    (cd "$WORK/emu" && git checkout --quiet "$EMU_COMMIT" && make -j"$(nproc)" >/dev/null)
    cp "$WORK/emu/build/x16emu" "$TOOLS/bin/"
    chmod +x "$TOOLS/bin/x16emu"
fi

# ---------------------------------------------------------------------------
# The ROM. This one is a KERNAL with the Assembler in ROM built into bank 16,
# which makes it both the machine xap runs on and, later, the thing to measure
# xap against on the same file and the same clock.
# ---------------------------------------------------------------------------

if have "$TOOLS/rom/rom.bin"; then
    echo "rom: already present"
else
    echo "rom: fetching $ROM_FILE"
    git clone --quiet --depth 1 "$ROM_REPO" "$WORK/rom"
    cp "$WORK/rom/$ROM_FILE" "$TOOLS/rom/rom.bin"
fi

echo
echo "toolchain ready:"
"$TOOLS/bin/64tass" --version | head -1
echo "  x16emu   $EMU_COMMIT"
echo "  rom      $ROM_FILE ($(stat -c%s "$TOOLS/rom/rom.bin") bytes)"
echo "  py65     $PY65_VERSION"
