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
# here: the source window at $2000, the symbol table and fixups from $3100.
# So the text being assembled goes above xap's code, where nothing else
# claims anything.
#
# It used to sit at $3000, which the symbol table grew over as soon as labels
# arrived -- the assembler read its own hash buckets as source and the tests
# that noticed looked like assembler bugs.
CODE = 0x6000        # where xap.bin is assembled to run, per the Makefile
RETURN = 0x0300      # below everything xap claims, and out of the window
SOURCE = 0xC000      # the text being assembled

# The object image is not in the flat 64K at all any more. It lives in banked
# RAM, which the X16 shows 8K at a time through a window at $A000 with the
# bank chosen by the byte at $00 -- so the harness has to model that much of
# the machine or it is testing something the machine does not do.
WINDOW = 0xA000
WINDOW_END = 0xC000
WINDOW_SIZE = WINDOW_END - WINDOW
RAMBANK = 0x00
IMAGE_BANK = 1       # bank 0 belongs to the KERNAL
IMAGE_BANKS = 8      # 64K, all a 65C02 program can be

# Zero page, mirroring src/xap.asm.
ZP = 0x22
SRC = ZP + 0
PC = ZP + 4
ORIGIN = ZP + 60

# A line of xap has no loops over anything unbounded, so a run that gets this
# far is stuck rather than slow.
STEP_LIMIT = 2000000


class BankedMemory:
    """Flat 64K, except the window at $A000, which shows one bank of many.

    py65 has no banking, and it does not need any in general -- so rather
    than an ObservableMemory with a callback on every address, which puts a
    dictionary lookup in front of every read the processor makes, this is one
    range check. That matters: the hotspot profiler steps about a million
    instructions and every one of them reads memory.
    """

    def __init__(self, banks=IMAGE_BANK + IMAGE_BANKS + 1):
        self.flat = bytearray(0x10000)
        self.banks = [bytearray(WINDOW_SIZE) for _ in range(banks)]

    def __getitem__(self, a):
        if isinstance(a, slice):
            return [self[i] for i in range(*a.indices(0x10000))]
        if WINDOW <= a < WINDOW_END:
            return self.banks[self.flat[RAMBANK]][a - WINDOW]

        return self.flat[a]

    def __setitem__(self, a, v):
        if isinstance(a, slice):
            for i, value in zip(range(*a.indices(0x10000)), v):
                self[i] = value
            return
        if WINDOW <= a < WINDOW_END:
            self.banks[self.flat[RAMBANK]][a - WINDOW] = v
        else:
            self.flat[a] = v

    def __len__(self):
        return 0x10000

    def image(self, size):
        """The first size bytes of the object image, across banks."""
        out = bytearray()
        for i in range(size):
            out.append(self.banks[IMAGE_BANK + (i >> 13)][i & 0x1FFF])

        return bytes(out)


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
        mpu = MPU(memory=BankedMemory())
        for i, b in enumerate(self.code):
            mpu.memory[CODE + i] = b

        body = text.encode("ascii") + b"\0"
        if SOURCE + len(body) > 0x10000:
            raise AssertionError("%d bytes of source does not fit above $%04X"
                                 % (len(body), SOURCE))
        for i, b in enumerate(body):
            mpu.memory[SOURCE + i] = b

        self._poke16(mpu, SRC, SOURCE)
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

        # The image and the program counter advance together, so how far the
        # counter has come is how much object code there is.
        size = self._peek16(mpu, PC) - self._peek16(mpu, ORIGIN)

        return mpu.memory.image(size)

    @staticmethod
    def _poke16(mpu, addr, value):
        mpu.memory[addr] = value & 0xFF
        mpu.memory[addr + 1] = (value >> 8) & 0xFF

    @staticmethod
    def _peek16(mpu, addr):
        return mpu.memory[addr] | (mpu.memory[addr + 1] << 8)
