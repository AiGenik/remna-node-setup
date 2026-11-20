import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
CLEAR = b"\x1b[H\x1b[2J"
TEST_KEY = "SYNTHETIC-UI-KEY"
ENV = {**os.environ, "TERM": "xterm-256color"}
ENV.pop("NO_COLOR", None)
FIXTURE = r'''
set -euo pipefail
source lib/common.sh
source lib/ui.sh
source lib/manager.sh
version_get() { printf '0.1.2\n'; }
apt_install_missing() { :; }
get_admin_ip() { ADMIN_IP=198.51.100.8; }
detect_ssh_port() { printf '2202\n'; }
load_config() { return 1; }
security_preflight() { :; }
node_preflight() { :; }
node_prepare_image() { :; }
prepare_security() { :; }
run_change() {
    [[ $NODE_DOMAIN == node.example.com && $NODE_PORT == 3333 && $SSH_PORT == 2202 &&
       $PANEL_IPS == 192.0.2.25 && $NEW_NODE_SECRET == SYNTHETIC-UI-KEY ]] || return 1
    printf 'TEST-APPLIED\n'
}
dispatch() {
    case "$1" in
        install) install_wizard ;;
        status) printf 'TEST-NODE-STATUS\n' ;;
    esac
}
PENDING_FILE=/dev/null
NODE_SECRET=/dev/null
ui_init
"$1"
'''


class Terminal:
    def __enter__(self):
        self.fd, slave = pty.openpty()
        self.output = b""
        self.process = subprocess.Popen(
            ["bash", "-c", FIXTURE, "ui-test", "show_menu"],
            cwd=ROOT, env=ENV, stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        return self

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        os.close(self.fd)

    def expect(self, text):
        marker = text.encode()
        deadline = time.monotonic() + 8
        while marker not in self.output:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise AssertionError(f"Missing {text!r}\n{self.output.decode(errors='replace')}")
            try:
                self.output += os.read(self.fd, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                raise AssertionError(self.output.decode(errors="replace")) from error
        consumed, self.output = self.output.split(marker, 1)
        return consumed

    def enter(self, text=""):
        os.write(self.fd, (text + "\n").encode())

    def wait_for_hidden_input(self):
        deadline = time.monotonic() + 2
        while termios.tcgetattr(self.fd)[3] & termios.ECHO:
            assert time.monotonic() < deadline, "The key prompt did not turn off echo"
            time.sleep(0.01)


with Terminal() as terminal:
    assert "Главное меню".encode() in terminal.expect("Номер пункта →")
    terminal.enter("3")
    screen = terminal.expect("Номер пункта →")
    assert CLEAR in screen and "Диагностика".encode() in screen.split(CLEAR)[-1]
    assert "Главное меню".encode() not in screen.split(CLEAR)[-1]
    terminal.enter("1")
    assert "TEST-NODE-STATUS".encode() in terminal.expect("Enter — вернуться в меню")
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    terminal.expect("Номер пункта →")
    terminal.enter("1")
    assert CLEAR in terminal.expect("Поддомен ноды →")
    terminal.enter("https://node.example.com")
    assert "Введите поддомен".encode() in terminal.expect("Поддомен ноды →")
    terminal.enter("node.example.com")
    screen = terminal.expect("NODE_PORT из панели →")
    assert CLEAR in screen and "Домен или IP".encode() in screen
    terminal.enter("  - NODE_PORT='3333'")
    assert "сервере, где установлена панель".encode() in terminal.expect("IP панели →")
    terminal.enter("192.0.2.25")
    terminal.expect("SSH-порт VPS → [2202]")
    terminal.enter()
    terminal.expect("Доверенные IP или подсети → [198.51.100.8]")
    terminal.enter()
    for component in ("Установить self-steal?", "Включить BBR и fq?", "Включить TrafficGuard?"):
        terminal.expect(component)
        terminal.enter("н")
    terminal.expect("SECRET_KEY из панели →")
    terminal.wait_for_hidden_input()
    terminal.enter(f'  - SECRET_KEY="{TEST_KEY}"')
    screen = terminal.expect("Начать установку?")
    assert TEST_KEY.encode() not in screen and b"3333" in screen
    terminal.enter("д")
    assert b"TEST-APPLIED" in terminal.expect("Enter — вернуться в меню")
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with_input = "\n".join(
    ["node.example.com", "NODE_PORT=3333", "192.0.2.25", "", "", "n", "n", "n", TEST_KEY, "y", ""]
)
plain = subprocess.run(
    ["bash", "-c", FIXTURE, "ui-test", "install_wizard"],
    cwd=ROOT, env=ENV, input=with_input, capture_output=True, text=True, check=True,
)
assert "TEST-APPLIED" in plain.stdout
assert "\x1b" not in plain.stdout + plain.stderr
assert TEST_KEY not in plain.stdout + plain.stderr
print("Проверены смена экранов, возврат в меню, повтор ввода и скрытый ключ в SSH-терминале.")
