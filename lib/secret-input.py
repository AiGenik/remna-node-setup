import os
import select
import signal
import sys
import termios
from copy import deepcopy


PASTE_END = b"\x1b[201~"


def escape_sequence(fd):
    sequence = bytearray()
    while len(sequence) < 16 and select.select([fd], [], [], 0.04)[0]:
        char = os.read(fd, 1)
        if not char:
            break
        sequence.extend(char)
        if sequence != b"[" and 0x40 <= char[0] <= 0x7E:
            break
    return sequence


def pasted_text(fd):
    pasted = bytearray()
    while char := os.read(fd, 1):
        pasted.extend(char)
        if pasted.endswith(PASTE_END):
            return pasted[:-len(PASTE_END)].rstrip(b"\r\n")
    raise EOFError


def read_secret(fd, prompt, redraw):
    value = bytearray()
    dirty = False
    print(prompt, end="", file=sys.stderr, flush=True)
    while True:
        if dirty and redraw and not select.select([fd], [], [], 0.035)[0]:
            print(f"\r\x1b[K{prompt}Введено {len(value)} симв.", end="", file=sys.stderr, flush=True)
            dirty = False

        char = os.read(fd, 1)
        if char in (b"\r", b"\n"):
            return value.decode()
        if not char or char == b"\x04":
            raise EOFError
        if char == b"\x1b":
            if escape_sequence(fd) == b"[200~":
                pasted = pasted_text(fd)
                if b"\n" in pasted or b"\r" in pasted:
                    value.clear()
                    print("\n  Скопируйте только поле Secret Key или одну строку SECRET_KEY.", file=sys.stderr)
                    print(prompt, end="", file=sys.stderr, flush=True)
                else:
                    value.extend(pasted)
        elif char in (b"\x08", b"\x7f"):
            del value[-1:]
        elif char == b"\x15":
            value.clear()
        elif char[0] >= 0x20:
            value.extend(char)
        dirty = True


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    prompt = sys.argv[1]
    redraw = sys.argv[2] == "yes"
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    private = deepcopy(original)
    # Noncanonical input avoids Linux's 4095-byte limit on a single line.
    private[3] &= ~(termios.ICANON | termios.ECHO)
    private[6][termios.VMIN] = 1
    private[6][termios.VTIME] = 0
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    termios.tcsetattr(fd, termios.TCSANOW, private)
    try:
        if redraw:
            print("\x1b[?2004h", end="", file=sys.stderr, flush=True)
        print(read_secret(fd, prompt, redraw))
    except (EOFError, KeyboardInterrupt, UnicodeError):
        return 1
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)
        print("\x1b[?2004l" if redraw else "", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
