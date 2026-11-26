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
source lib/psiphon.sh
source lib/port-preflight.sh
PROJECT_DIR=$PWD
CONFIG_DIR=$(mktemp -d)
STATE_DIR=$CONFIG_DIR
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
apt_install_missing() { :; }
release_wait_for_apt() { :; }
get_admin_ip() { ADMIN_IP=198.51.100.8; }
detect_ssh_port() { printf '2202\n'; }
security_detect_vpn_ports() { printf '9443/tcp\n'; }
ss() {
    if [[ ${FAIL_PREFLIGHT:-no} == yes && $2 == 'sport = :2443' ]]; then printf 'TEST-OTHER-SERVICE\n'; fi
}
security_preflight() { :; }
node_preflight() { :; }
selfsteal_preflight() { :; }
selfsteal_panel_help() { :; }
node_release_image() { printf 'remnawave/node:3.4.6@sha256:%064d\n' 0; }
node_prepare_image() {
    if [[ ${FAIL_IMAGE:-no} == yes ]]; then
        printf 'TEST-IMAGE-FAILED\n' >&2
        return 1
    fi
}
node_apply() { :; }
psiphon_is_managed() { return 1; }
_psiphon_existing_install() { return 1; }
_psiphon_default_port() { printf '1080\n'; }
_psiphon_install() {
    [[ -f $STATE_DIR/node-applied && $1 == NL && $2 == 1081 ]] || return 1
    printf 'TEST-PSIPHON\n'
    [[ ${FAIL_PSIPHON:-no} != yes ]]
}
ipv6_apply() { :; }
auto_update_configure() { printf 'TEST-AUTO-UPDATE\n'; }
auto_update_enabled() { return 1; }
prepare_security() { [[ $EXPECTED_MODE == full ]]; }
security_apply_current() { [[ $EXPECTED_MODE == full ]]; }
selfsteal_apply() { [[ $EXPECTED_MODE == full ]]; }
run_change() {
    local scope=$1
    shift
    [[ $NODE_PORT == 3333 && $NEW_NODE_SECRET == "$TEST_KEY" ]] || return 1
    if [[ $EXPECTED_MODE == full ]]; then
        [[ $NODE_DOMAIN == "${EXPECTED_DOMAIN:-}" && $SSH_PORT == 2202 &&
           $PANEL_IPS == 192.0.2.25 && $SELFSTEAL_SERVER == "$EXPECTED_WEBSERVER" &&
           $VPN_PORTS == '9443/tcp 2443/udp' && $scope == 'config node network'* ]] || return 1
    else
        [[ -z $NODE_DOMAIN && $ENABLE_SECURITY == no && -z $PANEL_IPS &&
           -z $SSH_PORT && $scope == 'config node' ]] || return 1
    fi
    "$@" || return 1
    load_config || return 1
    [[ $ENABLE_SECURITY == "$([[ $EXPECTED_MODE == full ]] && printf yes || printf no)" ]] || return 1
    touch "$STATE_DIR/node-applied" || return 1
    printf 'TEST-APPLIED\n'
    if [[ $EXPECTED_MODE == full ]]; then ui_network_confirmation; fi
}
dispatch() {
    case "$1" in
        install) install_wizard "${2-}" ;;
        preflight) standalone_port_preflight ;;
        status) printf 'TEST-NODE-STATUS\n' ;;
        versions) printf 'TEST-VERSIONS\n' ;;
        audit) printf 'TEST-AUDIT\n' ;;
        update) [[ $2 == tool ]] ;;
    esac
}
PENDING_FILE=$CONFIG_DIR/pending
if [[ ${TEST_PENDING:-no} == yes ]]; then printf 'test\n' > "$PENDING_FILE"; fi
network_rollback_remaining() { printf '123\n'; }
NODE_SECRET=$CONFIG_DIR/node.secret
RELEASE_COMMAND=$CONFIG_DIR/active-menu
cat > "$RELEASE_COMMAND" <<'MENU'
#!/usr/bin/env bash
printf 'TEST-REOPENED\n'
rm -f -- "$0"
rmdir -- "${0%/*}"
MENU
chmod +x "$RELEASE_COMMAND"
ui_init
"$1"
'''


class Terminal:
    def __init__(self, mode="full", fail_image=False, rows=24, columns=80, pending=False, no_color=False):
        self.mode = mode
        self.fail_image = fail_image
        self.rows = rows
        self.columns = columns
        self.pending = pending
        self.no_color = no_color

    def __enter__(self):
        self.fd, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.columns, 0, 0))
        self.output = b""
        env = {**ENV, "EXPECTED_WEBSERVER": "nginx", "EXPECTED_MODE": self.mode,
               "EXPECTED_DOMAIN": "node.example.com" if self.mode == "full" else "",
               "FAIL_IMAGE": "yes" if self.fail_image else "no",
               "TEST_PENDING": "yes" if self.pending else "no"}
        if self.no_color:
            env["NO_COLOR"] = "1"
        self.process = subprocess.Popen(
            ["bash", "-c", FIXTURE, "ui-test", "show_menu"],
            cwd=ROOT, env=env,
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
    assert "REMNA NODE SETUP" in screen and "◉" in screen
    assert "УСТАНОВКА И НАСТРОЙКА" in screen and "ПРОВЕРКА И СЕТЬ" in screen
    assert "[ 1] Всё под ключ" in screen and "[ 2] Установка и настройка по частям" in screen
    assert "Docker и подключение к панели" not in screen
    terminal.enter("3")
    screen = terminal.expect("Номер пункта →")
    assert CLEAR in screen and "Проверка и аудит работы ноды".encode() in screen.split(CLEAR)[-1]
    assert "ОБСЛУЖИВАНИЕ".encode() not in screen.split(CLEAR)[-1]
    terminal.enter("1")
    assert "TEST-NODE-STATUS".encode() in terminal.expect("Enter — вернуться в меню")
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    terminal.expect("Номер пункта →")
    terminal.enter("1")
    screen = terminal.expect("NODE_PORT из панели →")
    assert CLEAR in screen and "из Compose".encode() in screen
    assert "Адрес ноды →".encode() not in screen and "Домен self-steal →".encode() not in screen
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
    terminal.expect("Self-steal для REALITY (Nginx + Certbot)? [Y/n]")
    terminal.enter()
    terminal.expect("Домен self-steal →")
    terminal.enter("https://node.example.com")
    assert "Введите поддомен".encode() in terminal.expect("Домен self-steal →")
    terminal.enter("node.example.com")
    terminal.expect("Веб-сервер → [1]")
    terminal.enter()
    terminal.expect("Включить BBR и fq? [Y/n]")
    terminal.enter("д")
    terminal.expect("Введите y или n.")
    terminal.expect("Включить BBR и fq? [Y/n]")
    terminal.enter("n")
    terminal.expect("Отключить IPv6 на сервере? [Y/n]")
    terminal.enter("n")
    terminal.expect("Включить TrafficGuard (против сканеров)? [Y/n]")
    terminal.enter("n")
    terminal.expect("Настроить Gemini через Psiphon? [Y/n]")
    terminal.enter("y")
    terminal.expect("Регион Psiphon (auto, DE, NL, US) → [auto]")
    terminal.enter("nl")
    terminal.expect("Локальный порт SOCKS5 → [1080]")
    terminal.enter("1081")
    terminal.expect("Включить ночные автообновления (04:00)? [Y/n]")
    terminal.enter("n")
    terminal.expect("Порт SSH → [2202]")
    terminal.enter()
    assert "сервере панели".encode() in terminal.expect("IP панели →")
    terminal.enter("192.0.2.25")
    terminal.expect("Входящие порты VPN → [9443/tcp]")
    terminal.enter("9443/tcp 2443/udp")
    screen = without_ansi(terminal.expect("Показать команду для ручной проверки? [y/N]"))
    assert "Проверка соединения" in screen and "8443/tcp · локальный self-steal" in screen
    assert "3333/tcp · панель → нода" in screen and "9443/tcp · VPN" in screen
    assert "С компьютера · rns (или remna-ssh --panel)" in screen
    terminal.enter()
    screen = terminal.expect("Начать установку? [Y/n]")
    assert KEY_MARKER.encode() not in screen
    assert b"3333" in screen and b"nginx" in screen and b"9443/tcp 2443/udp" in screen
    assert b"Psiphon (NL)" in screen and b"127.0.0.1:1081" in screen
    assert termios.tcgetattr(terminal.fd)[3] & termios.ECHO
    terminal.enter("y")
    screen = terminal.expect("Enter — вернуться в меню")
    progress = without_ansi(screen)
    assert "TEST-APPLIED" in progress and "1 / 6" in progress and "6 / 6" in progress
    assert "›  Docker и образ ноды" in progress and "○  Контейнер Remnawave" in progress
    finished = without_ansi(screen.split(CLEAR)[-1])
    assert finished.count("✓") == 6 and "Установка завершена" in finished
    assert "Откройте [2] → [9]" in finished and "Сеть ждёт подтверждения SSH" in finished
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

base_inputs = ["NODE_PORT=3333", TEST_KEY, "n", "n", "n", "n"]
network_inputs = ["", "192.0.2.25", "9443/tcp 2443/udp", "y", ""]
plain = subprocess.run(
    ["bash", "-c", FIXTURE, "ui-test", "install_wizard"],
    cwd=ROOT, env={**ENV, "EXPECTED_WEBSERVER": "nginx", "EXPECTED_MODE": "full"},
    input="\n".join([*base_inputs, "n", "n", *network_inputs]), capture_output=True, text=True, check=True,
)
assert "TEST-APPLIED" in plain.stdout
assert "[1/4] Docker и образ ноды" in plain.stdout and "[4/4] Контейнер Remnawave" in plain.stdout
assert "TEST-PSIPHON" not in plain.stdout
assert "Домен self-steal →" not in plain.stderr and "Адрес ноды →" not in plain.stderr
assert "\x1b" not in plain.stdout + plain.stderr
assert TEST_KEY not in plain.stdout + plain.stderr

preflight_failed = subprocess.run(
    ["bash", "-c", FIXTURE, "ui-test", "install_wizard"],
    cwd=ROOT, env={**ENV, "EXPECTED_WEBSERVER": "nginx", "EXPECTED_MODE": "full", "FAIL_PREFLIGHT": "yes"},
    input="\n".join([*base_inputs, "n", "n", *network_inputs]), capture_output=True, text=True,
)
assert preflight_failed.returncode == 1
assert "Порт 2443/udp занят" in preflight_failed.stderr
assert "TEST-APPLIED" not in preflight_failed.stdout and "Начать установку" not in preflight_failed.stderr

psiphon_failed = subprocess.run(
    ["bash", "-c", FIXTURE, "ui-test", "install_wizard"],
    cwd=ROOT, env={**ENV, "EXPECTED_WEBSERVER": "nginx", "EXPECTED_MODE": "full", "FAIL_PSIPHON": "yes"},
    input="\n".join([*base_inputs, "y", "NL", "1081", "n", *network_inputs]),
    capture_output=True, text=True,
)
assert psiphon_failed.returncode == 1
assert "TEST-APPLIED" in psiphon_failed.stdout and "TEST-PSIPHON" in psiphon_failed.stdout
assert "Повторите настройку Gemini" in psiphon_failed.stderr
assert "Сеть ждёт подтверждения SSH" in psiphon_failed.stdout

def accept_minimal_install(terminal):
    terminal.expect("Номер пункта →")
    terminal.enter("2")
    assert "Установить только ноду".encode() in terminal.expect("Номер пункта →")
    terminal.enter("1")
    screen = terminal.expect("NODE_PORT из панели →")
    assert "Адрес ноды →".encode() not in screen
    terminal.enter("3333")
    terminal.expect("SECRET_KEY из панели →")
    terminal.wait_for_hidden_input()
    terminal.type_text(TEST_KEY)
    terminal.expect(f"Введено {len(TEST_KEY)} симв.")
    terminal.enter()
    screen = terminal.expect("Начать установку? [Y/n]")
    assert b"UFW" not in screen and b"Fail2Ban" not in screen and b"Gemini" not in screen
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
    terminal.enter("q")
    assert terminal.process.wait(timeout=5) == 0

with Terminal("node-only", fail_image=True) as terminal:
    accept_minimal_install(terminal)
    screen = without_ansi(terminal.expect("Enter — вернуться в меню").split(CLEAR)[-1])
    assert "×  Docker и образ ноды" in screen and "○  Контейнер Remnawave" in screen
    assert "TEST-IMAGE-FAILED" in screen and "Установка завершена" not in screen
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("q")
    assert terminal.process.wait(timeout=5) == 0

with Terminal(rows=18, columns=42, pending=True) as terminal:
    screen = terminal.expect("Номер пункта →")
    assert "\x1b[1;91m● Сеть ждёт подтверждения SSH".encode() in screen
    visible = without_ansi(screen)
    assert "[ 1] Всё под ключ" in visible and "[ 7] Где взять данные" in visible
    assert "sudo remna-node-setup confirm" in visible and "Автооткат через 2 мин 3 с." in visible
    assert len(visible.splitlines()) <= 18
    assert all(len(line) < 42 for line in visible.splitlines())
    for key, label in (
        ("2", "[ 2] Self-steal"),
        ("3", "[ 3] Живой тест"),
        ("5", "[ 5] Обновить TrafficGuard"),
        ("6", "[ 3] Подтвердить сетевые настройки"),
    ):
        terminal.enter(key)
        visible = without_ansi(terminal.expect("Номер пункта →").split(CLEAR)[-1])
        assert label in visible
        assert all(len(line) < 42 for line in visible.splitlines())
        terminal.enter("0")
        terminal.expect("Номер пункта →")
    terminal.enter("7")
    visible = without_ansi(terminal.expect("Enter — вернуться в меню").split(CLEAR)[-1])
    assert "Скопируйте Node Port и Secret Key." in visible
    assert len(visible.splitlines()) <= 18
    assert all(len(line) < 42 for line in visible.splitlines())
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with Terminal(pending=True, no_color=True) as terminal:
    screen = terminal.expect("Номер пункта →")
    visible = without_ansi(screen)
    assert CLEAR in screen
    assert set(re.findall(rb"\x1b\[([0-9;]+)m", screen)) == {b"0", b"1"}
    assert "● Сеть ждёт подтверждения SSH" in visible
    assert "sudo remna-node-setup confirm" in visible and "Автооткат через 2 мин 3 с." in visible
    terminal.enter("0")
    assert terminal.process.wait(timeout=5) == 0

with Terminal(rows=18, columns=32) as terminal:
    screen = without_ansi(terminal.expect("Номер пункта →"))
    assert "REMNA NODE SETUP" in screen and "[ 7] Где взять данные" in screen
    assert all(len(line) < 32 for line in screen.splitlines())
    terminal.enter("2")
    screen = without_ansi(terminal.expect("Номер пункта →").split(CLEAR)[-1])
    assert "[10] Восстановить" in screen and all(len(line) < 32 for line in screen.splitlines())
    terminal.enter("q")
    assert terminal.process.wait(timeout=5) == 0

with Terminal() as terminal:
    terminal.expect("Номер пункта →")
    terminal.enter("4")
    terminal.expect("Node Port из карточки ноды → [2222]")
    terminal.enter()
    terminal.expect("Порты VPN (TCP/UDP) → [443/tcp 9443/tcp]")
    terminal.enter()
    screen = without_ansi(terminal.expect("Показать команду для ручной проверки? [y/N]"))
    assert all(f"{port}/tcp" in screen for port in (2222, 443, 8443, 9443))
    terminal.enter()
    screen = without_ansi(terminal.expect("Enter — вернуться в меню"))
    assert "Внешний обмен не проверялся" in screen and "REMNA_PROBE" not in screen
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("q")
    assert terminal.process.wait(timeout=5) == 0

with Terminal() as terminal:
    terminal.expect("Номер пункта →")
    terminal.enter("5")
    screen = terminal.expect("Номер пункта →")
    assert "Актуальные версии".encode() in screen
    terminal.enter("1")
    assert "TEST-VERSIONS".encode() in terminal.expect("Enter — вернуться в меню")
    terminal.enter()
    terminal.expect("Номер пункта →")
    terminal.enter("7")
    terminal.expect("TEST-REOPENED")
    assert terminal.process.wait(timeout=5) == 0

print("Проверены мастер и отдельная проверка портов, Gemini, прогресс и перезапуск меню.")
