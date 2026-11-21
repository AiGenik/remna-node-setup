#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
CONFIG_DIR="$fixture/config"
mkdir -p -- "$CONFIG_DIR" "$fixture/systemd" "$fixture/release/lib"

# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/auto-update.sh
source "$project/lib/auto-update.sh"

AUTO_UPDATE_UNIT_DIR="$fixture/systemd"
AUTO_UPDATE_RELEASE_DIR="$fixture/release"
AUTO_UPDATE_COMMAND="$fixture/manager"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$AUTO_UPDATE_COMMAND"
chmod 0700 "$AUTO_UPDATE_COMMAND"
touch "$AUTO_UPDATE_RELEASE_DIR/lib/auto-update.sh"
service="$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.service"
timer="$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.timer"
marker="$CONFIG_DIR/auto-update.enabled"
MOCK_ACTIVATION_FAILURE=no
MOCK_FOREIGN_FRAGMENT=

systemctl() {
    printf '%s\n' "$*" >> "$fixture/systemctl.log"
    case $1 in
        show) printf '%s\n' "$MOCK_FOREIGN_FRAGMENT" ;;
        daemon-reload) : ;;
        is-active|is-enabled)
            [[ $* == "$1 --quiet $AUTO_UPDATE_UNIT.timer" && -e $fixture/timer-enabled ]]
            ;;
        enable)
            [[ $* == "enable --now $AUTO_UPDATE_UNIT.timer" && ! -e $marker ]] || return 1
            touch "$fixture/timer-enabled"
            [[ $MOCK_ACTIVATION_FAILURE == no ]]
            ;;
        disable)
            [[ $* == "disable --now $AUTO_UPDATE_UNIT.timer" && ! -e $marker ]] || return 1
            rm -f -- "$fixture/timer-enabled"
            ;;
        *) return 1 ;;
    esac
}

auto_update_configure status
if auto_update_enabled; then exit 1; fi
[[ ! -e $service && ! -e $timer && ! -e $marker && ! -e $fixture/systemctl.log ]]

UI_INTERACTIVE=yes
auto_update_configure <<< ''
[[ ! -e $timer ]]
auto_update_configure <<< y
auto_update_enabled
[[ $(< "$marker") == "$AUTO_UPDATE_CONSENT" ]]
grep -Fxq 'Persistent=true' "$timer"
grep -Fxq 'OnCalendar=*-*-* 04:00:00' "$timer"
grep -Fxq 'RandomizedDelaySec=15min' "$timer"
grep -Fxq "ConditionPathExists=$marker" "$service"
grep -Fxq "ConditionPathExists=$AUTO_UPDATE_RELEASE_DIR/lib/auto-update.sh" "$service"
grep -Fxq "ExecStart=$AUTO_UPDATE_COMMAND __auto-update" "$service"
grep -Fxq 'StandardInput=null' "$service"
grep -Fxq 'StandardOutput=journal' "$service"
auto_update_configure enable
[[ $(grep -c '^enable ' "$fixture/systemctl.log") == 1 ]]

auto_update_configure <<< ''
auto_update_enabled
auto_update_configure <<< y
[[ ! -e $fixture/timer-enabled && ! -e $marker ]]
if auto_update_enabled; then exit 1; fi

MOCK_ACTIVATION_FAILURE=yes
if auto_update_configure enable; then exit 1; fi
[[ ! -e $marker && ! -e $fixture/timer-enabled ]]
MOCK_ACTIVATION_FAILURE=no

printf '%s\n' 'foreign file' > "$timer"
cp -- "$service" "$fixture/service-before"
if auto_update_configure enable; then exit 1; fi
[[ $(< "$timer") == 'foreign file' && ! -e $marker ]]
cmp -- "$service" "$fixture/service-before"
rm -f -- "$timer"
ln -s -- "$fixture/service-before" "$timer"
if auto_update_configure enable; then exit 1; fi
[[ -L $timer ]]
rm -f -- "$timer"

MOCK_FOREIGN_FRAGMENT=/run/systemd/system/foreign.timer
if auto_update_configure enable; then exit 1; fi
[[ ! -e $timer && ! -e $marker ]]
MOCK_FOREIGN_FRAGMENT=
printf '%s\n' 'unknown marker' > "$marker"
if auto_update_configure enable || auto_update_configure disable; then exit 1; fi
[[ $(< "$marker") == 'unknown marker' && ! -e $fixture/timer-enabled ]]

printf '%s\n' 'Опциональный таймер, владение юнитами и безопасное отключение проверены.'
