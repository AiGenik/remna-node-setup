import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
SPLASH = ROOT / "lib/splash.py"
ENTRYPOINT = ROOT / "remna-node-setup"

CI_KEYS = (
    "CI",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "JENKINS_URL",
    "BUILDKITE",
    "CIRCLECI",
    "TRAVIS",
    "TF_BUILD",
)


def clean_tty_env(**overrides):
    env = dict(os.environ)
    for key in (*CI_KEYS, "NO_COLOR", "REMNA_NO_INTRO", "UI_NO_ANIMATION"):
        env.pop(key, None)
    env["TERM"] = "xterm-256color"
    env.update(overrides)
    return env


def run_pty(cmd, *, rows=24, cols=80, env=None, on_output=None, timeout=6.0, controlling_tty=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    output = bytearray()
    acted = False

    def _attach_ctty():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=clean_tty_env() if env is None else env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=_attach_ctty if controlling_tty else None,
    )
    os.close(slave)
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for {cmd!r}; output={output[-300:]!r}")
            rlist, _, _ = select.select([master], [], [], min(0.05, remaining))
            if rlist:
                try:
                    chunk = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
                if on_output is not None and not acted:
                    acted = bool(on_output(master, proc, output))
            elif proc.poll() is not None:
                # Drain any remaining buffered bytes after exit.
                while select.select([master], [], [], 0.02)[0]:
                    try:
                        chunk = os.read(master, 8192)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                break
        rc = proc.wait(timeout=2)
        attrs = termios.tcgetattr(master)
        lflag = attrs[3]
        # Verify no unread input leaked into the TTY buffer.
        leaked = bytearray()
        while select.select([master], [], [], 0.01)[0]:
            try:
                b = os.read(master, 1024)
            except OSError:
                break
            if not b:
                break
            leaked.extend(b)
        return rc, bytes(output), lflag, bytes(leaked)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=2)
        os.close(master)


# 1. Compilation, self-check, bash syntax, and --self-test / --help.
subprocess.run([sys.executable, "-m", "py_compile", str(SPLASH)], check=True)
subprocess.run([sys.executable, str(SPLASH), "--self-check"], check=True)
subprocess.run(["bash", "-n", str(ENTRYPOINT), str(ROOT / "lib/ui.sh")], check=True)
subprocess.run([str(ENTRYPOINT), "--self-test"], check=True)

help_res = subprocess.run([str(ENTRYPOINT), "--help"], capture_output=True, text=True, check=True)
assert "--no-intro" in help_res.stdout and "--demo-intro" in help_res.stdout

# 2. Full end-to-end short splash in PTY (80x24) -> alt screen, TrueColor, banner, clean restore.
rc, out, lflag, leaked = run_pty([sys.executable, str(SPLASH), "--duration", "0.45", "--version", "1.3.5"])
assert rc == 0, rc
assert b"\x1b[?1049h" in out and b"\x1b[?1049l" in out
assert b"\x1b[?25l" in out and b"\x1b[?25h" in out
assert b"\x1b[38;2;" in out
assert b"remna-node-setup" in out
assert b"\x1b[0m" in out
assert (lflag & termios.ECHO) and (lflag & termios.ICANON)
assert leaked == b""

# 3. Instant keypress skip (Enter, Space, Esc, q, and arrow sequence).
for key in (b"\r", b" ", b"\x1b", b"q", b"\x1b[A"):
    sent_at = [None]

    def send_key(master, _proc, buf, payload=key):
        if b"\x1b[38;2;" in buf:
            sent_at[0] = time.monotonic()
            os.write(master, payload)
            return True
        return False

    t0 = time.monotonic()
    rc, out, lflag, leaked = run_pty(
        [sys.executable, str(SPLASH), "--demo"],
        on_output=send_key,
        timeout=4.0,
    )
    elapsed = time.monotonic() - t0
    assert rc == 0, (key, rc)
    assert sent_at[0] is not None and elapsed < 2.0, (key, elapsed)
    assert b"\x1b[?1049l" in out and b"\x1b[?25h" in out
    assert (lflag & termios.ECHO) and (lflag & termios.ICANON)
    assert leaked == b"", (key, leaked)

# 4. Ctrl+C (SIGINT) and SIGTERM restore cursor, termios, colors, and alt screen.
def send_ctrl_c(master, _proc, buf):
    if b"\x1b[38;2;" in buf:
        os.write(master, b"\x03")
        return True
    return False


rc, out, lflag, _ = run_pty(
    [sys.executable, str(SPLASH), "--demo"],
    on_output=send_ctrl_c,
    timeout=4.0,
    controlling_tty=True,
)
assert rc == 128 + signal.SIGINT, rc
assert b"\x1b[?1049l" in out and b"\x1b[?25h" in out and b"\x1b[0m" in out
assert (lflag & termios.ECHO) and (lflag & termios.ICANON)

# Also verify direct SIGINT signal delivery without controlling TTY.
rc, out, lflag, _ = run_pty(
    [sys.executable, str(SPLASH), "--demo"],
    on_output=lambda _m, proc, buf: (proc.send_signal(signal.SIGINT) or True) if b"\x1b[38;2;" in buf else False,
    timeout=4.0,
)
assert rc == 128 + signal.SIGINT, rc
assert b"\x1b[?1049l" in out and b"\x1b[?25h" in out and b"\x1b[0m" in out
assert (lflag & termios.ECHO) and (lflag & termios.ICANON)


def send_sigterm(_master, proc, buf):
    if b"\x1b[38;2;" in buf:
        proc.terminate()
        return True
    return False


rc, out, lflag, _ = run_pty([sys.executable, str(SPLASH), "--demo"], on_output=send_sigterm, timeout=4.0)
assert rc in (128 + signal.SIGTERM, -signal.SIGTERM), rc
assert b"\x1b[?1049l" in out and b"\x1b[?25h" in out and b"\x1b[0m" in out
assert (lflag & termios.ECHO) and (lflag & termios.ICANON)

# 5. Non-interactive & environment fallbacks (no TrueColor, instant exit 0).
non_tty = subprocess.run(
    [sys.executable, str(SPLASH), "--demo"],
    env=clean_tty_env(),
    capture_output=True,
    timeout=3,
    check=True,
)
assert non_tty.stdout == b"" and non_tty.stderr == b""

cli_non_tty = subprocess.run(
    [str(ENTRYPOINT), "--demo-intro"],
    env=clean_tty_env(),
    capture_output=True,
    timeout=3,
    check=True,
)
assert b"\x1b[38;2;" not in cli_non_tty.stdout and b"\x1b[?1049h" not in cli_non_tty.stdout

for label, extra_env, extra_args, size in (
    ("TERM=dumb", {"TERM": "dumb"}, ["--demo"], (24, 80)),
    ("CI=true", {"CI": "true"}, ["--demo"], (24, 80)),
    ("NO_COLOR=1", {"NO_COLOR": "1"}, ["--demo"], (24, 80)),
    ("REMNA_NO_INTRO=1", {"REMNA_NO_INTRO": "1"}, [], (24, 80)),
    ("--no-intro", {}, ["--no-intro"], (24, 80)),
    ("small-term", {}, ["--demo"], (16, 45)),
):
    rc, out, lflag, _ = run_pty(
        [sys.executable, str(SPLASH), *extra_args],
        rows=size[0],
        cols=size[1],
        env=clean_tty_env(**extra_env),
        timeout=2.0,
    )
    assert rc == 0, (label, rc)
    assert b"\x1b[38;2;" not in out and b"\x1b[?1049h" not in out, (label, out)
    assert (lflag & termios.ECHO) and (lflag & termios.ICANON)

# 6. Entrypoint --demo-intro, --no-intro, and REMNA_NO_INTRO=1 in real PTY.
rc, out, lflag, _ = run_pty(
    [str(ENTRYPOINT), "--demo-intro"],
    on_output=lambda master, _proc, buf: (os.write(master, b"q") or True) if b"\x1b[38;2;" in buf else False,
    timeout=4.0,
)
assert rc == 0, rc
assert b"\x1b[38;2;" in out and b"\x1b[?1049h" in out and b"\x1b[?1049l" in out and b"\x1b[?25h" in out
assert (lflag & termios.ECHO) and (lflag & termios.ICANON)

rc, out, lflag, _ = run_pty([str(ENTRYPOINT), "--demo-intro", "--no-intro"], timeout=2.0)
assert rc != 0  # Proceeds to ensure_host without playing splash on non-Ubuntu/non-root host.
assert b"\x1b[38;2;" not in out and b"\x1b[?1049h" not in out

rc, out, lflag, _ = run_pty(
    [str(ENTRYPOINT), "--no-intro", "--version"],
    timeout=2.0,
)
assert rc == 0 and b"\x1b[38;2;" not in out and out.strip() != b""

# 7. Silent text-banner fallback when python3 is unavailable in PATH.
with tempfile.TemporaryDirectory() as tmpdir:
    bin_dir = Path(tmpdir) / "bin"
    bin_dir.mkdir()
    for tool in ("jq", "stty", "sleep", "cat", "tr"):
        resolved = shutil.which(tool)
        if resolved:
            (bin_dir / tool).symlink_to(resolved)
    fixture = (
        "set -euo pipefail\n"
        f"PROJECT_DIR={str(ROOT)!r}\n"
        "source \"$PROJECT_DIR/lib/common.sh\"\n"
        "source \"$PROJECT_DIR/lib/ui.sh\"\n"
        "ui_init\n"
        "ui_splash_intro demo\n"
    )
    rc, out, lflag, _ = run_pty(
        [shutil.which("bash"), "-c", fixture],
        env=clean_tty_env(PATH=str(bin_dir)),
        timeout=3.0,
    )
    assert rc == 0, rc
    assert b"REMNA NODE SETUP" in out
    assert b"python3" not in out and b"\x1b[38;2;" not in out
    assert (lflag & termios.ECHO) and (lflag & termios.ICANON)

print("Проверены ASCII TrueColor заставка, пропуск по клавише, Ctrl+C/SIGTERM, fallback без TTY и без python3.")
