import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
CLEAR = b"\x1b[H\x1b[2J"
KEY_MARKER = "SYNTHETIC-UI-KEY"
TEST_KEY = KEY_MARKER + "A" * 7184
ENV = {**os.environ, "TERM": "xterm-256color", "TEST_KEY": TEST_KEY}
ENV.pop("NO_COLOR", None)
FIXTURE = r'''
set -euo pipefail
source lib/common.sh
source lib/ui.sh
source lib/manager.sh
source lib/security.sh
source lib/standalone.sh
PROJECT_DIR=$PWD
CONFIG_DIR=$(mktemp -d)
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
apt_install_missing() { :; }
get_admin_ip() { ADMIN_IP=198.51.100.8; }
detect_ssh_port() { printf '2202\n'; }
security_detect_vpn_ports() { printf '9443/tcp\n'; }
security_preflight() { :; }
node_preflight() { :; }
selfsteal_preflight() { :; }
selfsteal_panel_help() { :; }
node_prepare_image() {
    if [[ ${FAIL_IMAGE:-no} == yes ]]; then
        printf 'TEST-IMAGE-FAILED\n' >&2
        return 1
    fi
}
node_apply() { :; }
prepare_security() { [[ $EXPECTED_MODE == full ]]; }
security_apply_current() { [[ $EXPECTED_MODE == full ]]; }
selfsteal_apply() { [[ $EXPECTED_MODE == full ]]; }
run_change() {
    local scope=$1
    shift
    [[ $NODE_PORT == 3333 && $NEW_NODE_SECRET == "$TEST_KEY" ]] || return 1
    if [[ $EXPECTED_MODE == full ]]; then
        [[ $NODE_DOMAIN == node.example.com && $SSH_PORT == 2202 &&
           $PANEL_IPS == 192.0.2.25 && $SELFSTEAL_SERVER == "$EXPECTED_WEBSERVER" &&
           $VPN_PORTS == '9443/tcp 2443/udp' && $scope == 'config node network'* ]] || return 1
    else
        [[ $NODE_DOMAIN == 192.0.2.10 && $ENABLE_SECURITY == no && -z $PANEL_IPS &&
           -z $SSH_PORT && $scope == 'config node' ]] || return 1
    fi
    "$@" || return 1
    load_config || return 1
    [[ $ENABLE_SECURITY == "$([[ $EXPECTED_MODE == full ]] && printf yes || printf no)" ]] || return 1
    printf 'TEST-APPLIED\n'
}
dispatch() {
    case "$1" in
        install) install_wizard "${2-}" ;;
        status) printf 'TEST-NODE-STATUS\n' ;;
    esac
}
PENDING_FILE=$CONFIG_DIR/pending
if [[ ${TEST_PENDING:-no} == yes ]]; then printf 'test\n' > "$PENDING_FILE"; fi
network_rollback_remaining() { printf '123\n'; }
NODE_SECRET=$CONFIG_DIR/node.secret
ui_init
"$1"
'''


class Terminal:
    def __init__(self, mode="full", fail_image=False, rows=24, columns=80, pending=False):
        self.mode = mode
        self.fail_image = fail_image
        self.rows = rows
        self.columns = columns
        self.pending = pending

    def __enter__(self):
        self.fd, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.columns, 0, 0))
        self.output = b""
        self.process = subprocess.Popen(
            ["bash", "-c", FIXTURE, "ui-test", "show_menu"],
            cwd=ROOT, env={**ENV, "EXPECTED_WEBSERVER": "nginx", "EXPECTED_MODE": self.mode,
                           "FAIL_IMAGE": "yes" if self.fail_image else "no",
                           "TEST_PENDING": "yes" if self.pending else "no"},
            stdin=slave, stdout=slave, stderr=slave,
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
        self.type_text(text + "\n")

    def type_text(self, text):
        pending = memoryview(text.encode())
        while pending:
            pending = pending[os.write(self.fd, pending):]

    def wait_for_hidden_input(self):
        deadline = time.monotonic() + 2
        while termios.tcgetattr(self.fd)[3] & termios.ECHO:
            assert time.monotonic() < deadline, "The key prompt did not turn off echo"
            time.sleep(0.01)


def without_ansi(screen):
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", screen).decode()


with Terminal() as terminal:
    screen = without_ansi(terminal.expect("Номер пункта →"))
    assert "◆─●  REMNA NODE SETUP" in screen
    assert "УСТАНОВКА" in screen and "УПРАВЛЕНИЕ" in screen
    assert "[1] Только нода" in screen and "[2] Нода и компоненты" in screen
    terminal.enter("4")
    screen = terminal.expect("Номер пункта →")
    assert CLEAR in screen and "Диагностика".encode() in screen.split(CLEAR)[-1]
    assert "УПРАВЛЕНИЕ".encode() not in screen.split(CLEAR)[-1]
    terminal.enter("1")
    assert "TEST-NODE-STATUS".encode() in terminal.expect("Enter — вернуться в меню")
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    terminal.expect("Номер пункта →")
    terminal.enter("2")
    assert CLEAR in terminal.expect("Адрес ноды →")
    terminal.enter("https://node.example.com")
    assert "Введите домен или публичный IP".encode() in terminal.expect("Адрес ноды →")
    terminal.enter("node.example.com")
    screen = terminal.expect("NODE_PORT из панели →")
    assert "из Compose".encode() in screen
    terminal.enter("  - NODE_PORT='3333'")
    terminal.expect("SECRET_KEY из панели →")
    terminal.wait_for_hidden_input()
    terminal.type_text(TEST_KEY)
    screen = terminal.expect(f"Введено {len(TEST_KEY)} симв.")
    assert KEY_MARKER.encode() not in screen
    terminal.type_text("\x15")
    terminal.expect("Введено 0 симв.")
    compose = f'  - SECRET_KEY="{TEST_KEY}"'
    terminal.type_text(f"\x1b[200~{compose}\n\x1b[201~")
    screen = terminal.expect(f"Введено {len(compose)} симв.")
    assert KEY_MARKER.encode() not in screen
    terminal.enter()
    terminal.expect("HTTPS-страница для REALITY? [Y/n]")
    terminal.enter()
    terminal.expect("Веб-сервер → [1]")
    terminal.enter("2")
    terminal.expect("оптимизация TCP? [Y/n]")
    terminal.enter("invalid")
    terminal.expect("Введите y или n.")
    terminal.expect("оптимизация TCP? [Y/n]")
    terminal.enter("n")
    terminal.expect("блокировка известных сканеров? [y/N]")
    terminal.enter("n")
    terminal.expect("Порт SSH → [2202]")
    terminal.enter()
    assert "сервере панели".encode() in terminal.expect("IP панели →")
    terminal.enter("192.0.2.25")
    terminal.expect("Входящие порты VPN → [9443/tcp]")
    terminal.enter("9443/tcp 2443/udp")
    screen = terminal.expect("Начать установку? [y/N]")
    assert KEY_MARKER.encode() not in screen
    assert b"3333" in screen and b"nginx" in screen and b"9443/tcp 2443/udp" in screen
    assert termios.tcgetattr(terminal.fd)[3] & termios.ECHO
    terminal.enter("y")
    screen = terminal.expect("Enter — вернуться в меню")
    progress = without_ansi(screen)
    assert "TEST-APPLIED" in progress and "1 / 5" in progress and "5 / 5" in progress
    assert "›  Docker и образ ноды" in progress and "○  Контейнер Remnawave" in progress
    finished = without_ansi(screen.split(CLEAR)[-1])
    assert finished.count("✓") == 5 and "Установка завершена" in finished
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with_input = "\n".join(
    ["node.example.com", "NODE_PORT=3333", TEST_KEY, "n", "n", "n", "", "192.0.2.25",
     "9443/tcp 2443/udp", "y", ""]
)
plain = subprocess.run(
    ["bash", "-c", FIXTURE, "ui-test", "install_wizard"],
    cwd=ROOT, env={**ENV, "EXPECTED_WEBSERVER": "caddy", "EXPECTED_MODE": "full"},
    input=with_input, capture_output=True, text=True, check=True,
)
assert "TEST-APPLIED" in plain.stdout
assert "[1/4] Docker и образ ноды" in plain.stdout and "[4/4] Контейнер Remnawave" in plain.stdout
assert "\x1b" not in plain.stdout + plain.stderr
assert TEST_KEY not in plain.stdout + plain.stderr

def accept_minimal_install(terminal):
    assert "Только нода".encode() in terminal.expect("Номер пункта →")
    terminal.enter("1")
    terminal.expect("Адрес ноды →")
    terminal.enter("192.0.2.10")
    terminal.expect("NODE_PORT из панели →")
    terminal.enter("3333")
    terminal.expect("SECRET_KEY из панели →")
    terminal.wait_for_hidden_input()
    terminal.type_text(TEST_KEY)
    terminal.expect(f"Введено {len(TEST_KEY)} симв.")
    terminal.enter()
    screen = terminal.expect("Начать установку? [y/N]")
    assert b"UFW" not in screen and b"Fail2Ban" not in screen
    terminal.enter("y")


with Terminal("node-only") as terminal:
    accept_minimal_install(terminal)
    screen = terminal.expect("Enter — вернуться в меню")
    progress = without_ansi(screen)
    assert "TEST-APPLIED" in progress and "1 / 2" in progress and "2 / 2" in progress
    assert without_ansi(screen.split(CLEAR)[-1]).count("✓") == 2
    assert b"UFW" not in screen and b"Fail2Ban" not in screen and KEY_MARKER.encode() not in screen
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with Terminal("node-only", fail_image=True) as terminal:
    accept_minimal_install(terminal)
    screen = without_ansi(terminal.expect("Enter — вернуться в меню").split(CLEAR)[-1])
    assert "×  Docker и образ ноды" in screen and "○  Контейнер Remnawave" in screen
    assert "TEST-IMAGE-FAILED" in screen and "Установка завершена" not in screen
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with Terminal(rows=18, columns=42) as terminal:
    screen = without_ansi(terminal.expect("Номер пункта →"))
    assert "[1] Только нода" in screen and "Docker и подключение к панели" not in screen
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with Terminal(pending=True) as terminal:
    screen = terminal.expect("Номер пункта →")
    assert "\x1b[1;91m● Сеть ждёт подтверждения SSH".encode() in screen
    visible = without_ansi(screen)
    assert "sudo remna-node-setup confirm" in visible and "Автооткат через 2 мин 3 с." in visible
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

print("Проверены мастер, прогресс, скрытый ввод и красное предупреждение об автооткате.")
