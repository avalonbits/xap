"""Runs xap on the host.

xap is 65C02 code, so testing it means executing 65C02 code. py65 does that
in-process, which keeps the test loop to a few milliseconds and needs no
emulator, no SD card image and no ROM. Nothing in this stage of xap touches
the KERNAL or the VERA, so there is nothing the bare CPU cannot provide; when
file I/O arrives it will need the real emulator and this harness will only
cover the parts below it.
"""

import os

from py65.devices.mpu65c02 import MPU

ROOT = os.path.join(os.path.dirname(__file__), "..")
BINARY = os.path.join(ROOT, "build", "xap.bin")

# xap's own working memory is fixed by src/xap.asm and cannot be moved from
# here: the source window at $2000, the symbol table and fixups from $3100,
# and the object image from $4000. So the text being assembled goes above
# xap's code, where nothing else claims anything.
#
# It used to sit at $3000, which the symbol table grew over as soon as labels
# arrived -- the assembler read its own hash buckets as source and the tests
# that noticed looked like assembler bugs.
CODE = 0x6000        # where xap.bin is assembled to run, per the Makefile
OUTPUT = 0x4000      # the object image, as src/xap.asm places it
RETURN = 0xBF00      # above the code, below the source
SOURCE = 0xC000      # the text being assembled

# Zero page, mirroring src/xap.asm.
ZP = 0x22
SRC = ZP + 0
OUT = ZP + 2
PC = ZP + 4

# A line of xap has no loops over anything unbounded, so a run that gets this
# far is stuck rather than slow.
STEP_LIMIT = 2000000


class Error(Exception):
    """xap returned an error code."""

    def __init__(self, code):
        super().__init__("xap error $%02X" % code)
        self.code = code


class Xap:
    def __init__(self, binary=BINARY):
        with open(binary, "rb") as fh:
            self.code = fh.read()

    def assemble(self, text, origin=0x1000):
        """Assembles text and returns the object bytes.

        Raises Error with the code xap reported, so a test can assert on the
        failure as precisely as on the output.
        """
        mpu = MPU()
        for i, b in enumerate(self.code):
            mpu.memory[CODE + i] = b

        body = text.encode("ascii") + b"\0"
        if SOURCE + len(body) > 0x10000:
            raise AssertionError("%d bytes of source does not fit above $%04X"
                                 % (len(body), SOURCE))
        for i, b in enumerate(body):
            mpu.memory[SOURCE + i] = b

        self._poke16(mpu, SRC, SOURCE)
        self._poke16(mpu, OUT, OUTPUT)
        self._poke16(mpu, PC, origin)

        # RTS returns to the address after the one on the stack, so what goes
        # on is one short of where execution should stop.
        mpu.sp = 0xFF
        mpu.memory[0x0100 + mpu.sp] = ((RETURN - 1) >> 8) & 0xFF
        mpu.sp -= 1
        mpu.memory[0x0100 + mpu.sp] = (RETURN - 1) & 0xFF
        mpu.sp -= 1

        mpu.pc = CODE
        steps = 0
        while mpu.pc != RETURN:
            mpu.step()
            steps += 1
            if steps > STEP_LIMIT:
                raise AssertionError(
                    "xap did not return after %d instructions, pc=$%04X"
                    % (STEP_LIMIT, mpu.pc))

        if mpu.p & 0x01:                       # carry set: failed
            raise Error(mpu.a)

        end = self._peek16(mpu, OUT)

        return bytes(mpu.memory[OUTPUT:end])

    @staticmethod
    def _poke16(mpu, addr, value):
        mpu.memory[addr] = value & 0xFF
        mpu.memory[addr + 1] = (value >> 8) & 0xFF

    @staticmethod
    def _peek16(mpu, addr):
        return mpu.memory[addr] | (mpu.memory[addr + 1] << 8)
