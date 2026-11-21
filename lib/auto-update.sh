#!/usr/bin/env bash

AUTO_UPDATE_UNIT=remna-node-setup-auto-update
AUTO_UPDATE_UNIT_DIR=/etc/systemd/system
AUTO_UPDATE_COMMAND=/usr/local/bin/remna-node-setup
AUTO_UPDATE_RELEASE_DIR=/opt/remna-node-setup/current
AUTO_UPDATE_UNIT_MARKER='# Managed by Remna Node Setup auto-update'
AUTO_UPDATE_CONSENT='remna-node-setup auto-update v1'

_auto_update_regular_owned() {
    local path=$1 mode
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    mode=$(stat -c %a -- "$path") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 ))
}

_auto_update_opted_in() {
    local marker="$CONFIG_DIR/auto-update.enabled"
    _auto_update_regular_owned "$marker" && [[ $(< "$marker") == "$AUTO_UPDATE_CONSENT" ]]
}

_auto_update_unit_owned() {
    local path=$1 marker
    _auto_update_regular_owned "$path" &&
        IFS= read -r marker < "$path" &&
        [[ $marker == "$AUTO_UPDATE_UNIT_MARKER" ]]
}

_auto_update_unit_slot() {
    local unit=$1 path="$AUTO_UPDATE_UNIT_DIR/$1" fragment
    if [[ ( -e $path || -L $path ) ]] && ! _auto_update_unit_owned "$path"; then
        fail "Файл $path не принадлежит Remna Node Setup."
        return 1
    fi
    fragment=$(systemctl show --property=FragmentPath --value "$unit") || return 1
    if [[ -n $fragment && $fragment != "$path" ]]; then
        fail "Имя $unit уже используется файлом $fragment."
        return 1
    fi
}

auto_update_enabled() {
    _auto_update_opted_in &&
        _auto_update_unit_owned "$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.service" &&
        _auto_update_unit_owned "$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.timer" &&
        systemctl is-enabled --quiet "$AUTO_UPDATE_UNIT.timer"
}

auto_update_status() {
    local marker="$CONFIG_DIR/auto-update.enabled"
    if [[ ! -e $marker && ! -L $marker ]]; then
        info 'Автообновления выключены.'
    elif ! auto_update_enabled || ! systemctl is-active --quiet "$AUTO_UPDATE_UNIT.timer"; then
        warn 'Настройка автообновлений или таймер недоступны.'
        return 1
    else
        info 'Автообновления включены. Ежедневно в 04:00 по времени VPS, задержка до 15 минут.'
    fi
}

_auto_update_write_units() (
    local stage
    stage=$(mktemp -d "$AUTO_UPDATE_UNIT_DIR/.remna-auto-update.XXXXXX") || return
    trap 'rm -rf -- "$stage"' EXIT
    cat > "$stage/service" <<UNIT || return
$AUTO_UPDATE_UNIT_MARKER
[Unit]
Description=Remna Node Setup automatic updates
Wants=network-online.target
After=network-online.target
ConditionPathExists=$CONFIG_DIR/auto-update.enabled
ConditionPathExists=$AUTO_UPDATE_RELEASE_DIR/lib/auto-update.sh

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
ExecStart=$AUTO_UPDATE_COMMAND __auto-update
StandardInput=null
StandardOutput=journal
StandardError=journal
UMask=0077
TimeoutStartSec=45min
UNIT
    cat > "$stage/timer" <<UNIT || return
$AUTO_UPDATE_UNIT_MARKER
[Unit]
Description=Daily Remna Node Setup automatic updates

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=15min
AccuracySec=1us
Persistent=true
Unit=$AUTO_UPDATE_UNIT.service

[Install]
WantedBy=timers.target
UNIT
    chmod 0644 "$stage/service" "$stage/timer" &&
        mv -Tf -- "$stage/service" "$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.service" &&
        mv -Tf -- "$stage/timer" "$AUTO_UPDATE_UNIT_DIR/$AUTO_UPDATE_UNIT.timer"
)

_auto_update_record_consent() (
    local marker
    marker=$(mktemp "$CONFIG_DIR/.auto-update.enabled.XXXXXX") || return
    trap 'rm -f -- "$marker"' EXIT
    printf '%s\n' "$AUTO_UPDATE_CONSENT" > "$marker" &&
        mv -Tf -- "$marker" "$CONFIG_DIR/auto-update.enabled"
)

_auto_update_enable() {
    local marker="$CONFIG_DIR/auto-update.enabled"
    [[ -x $AUTO_UPDATE_COMMAND && -f $AUTO_UPDATE_RELEASE_DIR/lib/auto-update.sh ]] ||
        { fail 'Сначала установите текущую версию Remna Node Setup.'; return 1; }
    if [[ ( -e $marker || -L $marker ) ]] && ! _auto_update_opted_in; then
        fail "Файл $marker не принадлежит Remna Node Setup."
        return 1
    fi
    _auto_update_unit_slot "$AUTO_UPDATE_UNIT.service" && _auto_update_unit_slot "$AUTO_UPDATE_UNIT.timer" || return
    if auto_update_enabled && systemctl is-active --quiet "$AUTO_UPDATE_UNIT.timer"; then
        auto_update_status
        return
    fi
    _auto_update_write_units && systemctl daemon-reload || return
    if ! systemctl enable --now "$AUTO_UPDATE_UNIT.timer" ||
       ! systemctl is-active --quiet "$AUTO_UPDATE_UNIT.timer" ||
       ! _auto_update_record_consent; then
        if ! _auto_update_opted_in; then
            systemctl disable --now "$AUTO_UPDATE_UNIT.timer" || :
        fi
        fail 'Не удалось активировать автообновления.'
        return 1
    fi
    auto_update_status
}

_auto_update_disable() {
    local marker="$CONFIG_DIR/auto-update.enabled" timer="$AUTO_UPDATE_UNIT.timer"
    if [[ -e $marker || -L $marker ]]; then
        _auto_update_opted_in || { fail "Файл $marker не принадлежит Remna Node Setup."; return 1; }
        rm -f -- "$marker" || return
    fi
    # Removing opt-in first prevents work even if systemd cannot stop the timer.
    if _auto_update_unit_owned "$AUTO_UPDATE_UNIT_DIR/$timer"; then
        _auto_update_unit_slot "$timer" && systemctl disable --now "$timer" || return
    fi
    auto_update_status
}

auto_update_configure() {
    local action=${1-} answer
    if (( $# > 1 )); then
        fail 'Используйте auto-updates enable, disable или status.'
        return 2
    fi
    case $action in
        enable) _auto_update_enable ;;
        disable) _auto_update_disable ;;
        status) auto_update_status ;;
        '')
            auto_update_status || :
            if [[ ${UI_INTERACTIVE:-no} != yes ]]; then return 0; fi
            if _auto_update_opted_in; then
                answer=$(yes_no 'Выключить автообновления?' n) || return
                if [[ $answer == yes ]]; then _auto_update_disable; fi
            else
                answer=$(yes_no 'Включить ежедневные автообновления?' n) || return
                if [[ $answer == yes ]]; then _auto_update_enable; fi
            fi
            ;;
        *) fail 'Используйте auto-updates enable, disable или status.'; return 2 ;;
    esac
}
