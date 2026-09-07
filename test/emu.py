"""Drives x16emu in testbench mode.

The emulator's testbench mode boots the machine normally -- KERNAL, BASIC and
all -- and then pastes SYS65533 to drop into a command loop on stdin. Commands
set and read memory and registers; RUN starts code and the loop is re-entered
when it returns. Closing stdin exits the emulator.

That gives everything a benchmark needs: the real KERNAL, real file I/O through
HostFS, and the emulator's own cycle counter. What it does not give is a fast
way in -- STM writes one byte per command -- so the source file goes through
HostFS rather than through the command stream, which is the realistic path
anyway.
"""

import os
import queue
import subprocess
import threading

ROOT = os.path.join(os.path.dirname(__file__), "..")

# Where the emulator, its ROM and a scratch HostFS directory are. There is no
# sensible default for these, so the environment says.
EMULATOR = os.environ.get("X16EMU", "")
ROM = os.environ.get("X16ROM", "")


class Emulator:
    """One emulator process, in testbench mode."""

    def __init__(self, fsroot, exe=None, rom=None, warp=True, timeout=120):
        self.exe = exe or EMULATOR
        self.rom = rom or ROM
        self.fsroot = fsroot
        self.timeout = timeout

        argv = [self.exe, "-testbench", "-sound", "none", "-fsroot", fsroot]
        if self.rom:
            argv += ["-rom", self.rom]
        if warp:
            argv.append("-warp")

        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
            cwd=os.path.dirname(self.exe) or None)

        # stdout is drained by a thread. Loading a few kilobytes means a few
        # thousand replies, and writing that many commands without reading
        # would fill the pipe and deadlock both ends.
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()

        self._expect("RDY")

    def _drain(self):
        for line in self.proc.stdout:
            line = line.strip()
            if line and line != "Testbench mode...":
                self.lines.put(line)
        self.lines.put(None)

    def _line(self):
        try:
            line = self.lines.get(timeout=self.timeout)
        except queue.Empty:
            raise AssertionError("emulator went quiet for %ds" % self.timeout)
        if line is None:
            raise AssertionError("emulator exited unexpectedly")

        return line

    def _expect(self, want):
        got = self._line()
        if got != want:
            raise AssertionError("expected %r from the emulator, got %r"
                                 % (want, got))

    def _send(self, command):
        self.proc.stdin.write(command + "\n")

    def _command(self, command):
        self._send(command)
        self.proc.stdin.flush()

    # ---- memory --------------------------------------------------------

    def load(self, addr, data):
        """Writes a block of memory, one STM per byte.

        Commands are sent without waiting for each reply and the replies are
        counted at the end, which turns a few thousand round trips into one.
        """
        for i, b in enumerate(data):
            self._send("STM %04X %02X" % (addr + i, b))
        self.proc.stdin.flush()
        for _ in data:
            self._expect("RDY")

    def poke(self, addr, value):
        self._command("STM %04X %02X" % (addr, value & 0xFF))
        self._expect("RDY")

    def poke16(self, addr, value):
        self.load(addr, bytes([value & 0xFF, (value >> 8) & 0xFF]))

    def peek(self, addr):
        self._command("RQM %04X" % addr)

        return int(self._line(), 16)

    def peek_block(self, addr, count):
        for i in range(count):
            self._send("RQM %04X" % (addr + i))
        self.proc.stdin.flush()

        return bytes(int(self._line(), 16) for _ in range(count))

    def peek32(self, addr):
        b = self.peek_block(addr, 4)

        return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24

    # ---- execution -----------------------------------------------------

    def run(self, addr):
        """Runs from addr and returns when it RTSs."""
        self._command("RUN %04X" % addr)
        self._expect("RDY")

    def close(self):
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.reader.join(timeout=5)
        if self.proc.stdout:
            self.proc.stdout.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def labels(path):
    """Reads a 64tass label file into {name: address}.

    Building the driver together with xap and then reading the addresses back
    out means the harness is never told where anything is, so a buffer can
    move without the two silently disagreeing about the layout.
    """
    out = {}
    with open(path) as fh:
        for line in fh:
            name, _, value = line.partition("=")
            name, value = name.strip(), value.strip()
            if name and value.startswith("$"):
                out[name] = int(value[1:], 16)

    return out


def petscii(name):
    """The KERNAL wants a file name in upper case PETSCII."""
    return name.upper().encode("ascii")
