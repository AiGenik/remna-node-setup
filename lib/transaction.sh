#!/usr/bin/env bash

SNAPSHOT_CONFIG=("$CONFIG_DIR/node.json" "$CONFIG_DIR/host.json" "$NODE_SECRET")
SNAPSHOT_NODE=("$NODE_DIR/compose.yaml" /etc/logrotate.d/remna-node-setup /etc/logrotate.d/remna-node-setup-node)
SNAPSHOT_CADDY=(/etc/caddy/Caddyfile /var/www/remna-node-setup/index.html)
SNAPSHOT_NGINX=(/etc/nginx/conf.d/remna-node-setup.conf
    /etc/systemd/system/remna-node-setup-certbot.service /etc/systemd/system/remna-node-setup-certbot.timer)
SELFSTEAL_UNITS=(caddy.service nginx.service remna-node-setup-certbot.timer)
SNAPSHOT_NETWORK=(/etc/ufw /etc/default/ufw /etc/fail2ban/jail.d/remna-node-setup.local
    /etc/ipset.conf /etc/systemd/system/antiscan-ipset-restore.service
    /etc/systemd/system/antiscan-move-rules.service "$STATE_DIR/traffic-guard")
SNAPSHOT_BBR=(/etc/sysctl.d/90-remna-node-setup-bbr.conf)
TG_UNITS=(antiscan-ipset-restore.service antiscan-move-rules.service)
ROLLBACK_UNIT=remna-node-setup-rollback
PENDING_FILE=$STATE_DIR/pending

path_snapshot() {
    local dir=$1 path
    shift
    for path in "$@"; do
        if [[ -e $path || -L $path ]]; then
            mkdir -p -- "$dir/files${path%/*}" || return
            cp -a -- "$path" "$dir/files$path" || return
        fi
    done
}

path_restore() {
    local dir=$1 path backup
    shift
    for path in "$@"; do
        backup=$dir/files$path
        if [[ ! -e $path && ! -L $path && ! -e $backup && ! -L $backup ]]; then
            continue
        fi
        rm -rf -- "$path" || return
        if [[ -e $backup || -L $backup ]]; then
            mkdir -p -- "${path%/*}" || return
            cp -a -- "$backup" "$path" || return
        fi
    done
}

valid_snapshot_id() {
    [[ $1 =~ ^[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{6}$ ]]
}

has_scope() {
    [[ " $1 " == *" $2 "* ]]
}

capture_snapshot() {
    local scope=$1 dir unit
    dir=$(mktemp -d "$BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return
    mkdir -- "$dir/files" || return
    if has_scope "$scope" config; then path_snapshot "$dir" "${SNAPSHOT_CONFIG[@]}" || return; fi
    if has_scope "$scope" node; then path_snapshot "$dir" "${SNAPSHOT_NODE[@]}" || return; fi
    if has_scope "$scope" selfsteal; then
        path_snapshot "$dir" "${SNAPSHOT_CADDY[@]}" "${SNAPSHOT_NGINX[@]}" || return
        for unit in "${SELFSTEAL_UNITS[@]}"; do
            active "$unit" > "$dir/${unit%.*}.active" || return
            enabled "$unit" > "$dir/${unit%.*}.enabled" || return
        done
    fi
    if has_scope "$scope" bbr; then
        path_snapshot "$dir" "${SNAPSHOT_BBR[@]}" || return
        sysctl -n net.core.default_qdisc > "$dir/qdisc" 2>/dev/null || :
        sysctl -n net.ipv4.tcp_congestion_control > "$dir/cc" 2>/dev/null || :
    fi
    if has_scope "$scope" network; then
        path_snapshot "$dir" "${SNAPSHOT_NETWORK[@]}" || return
        if LC_ALL=C ufw status | grep -q '^Status: active'; then
            printf 'yes\n' > "$dir/ufw.active"
        else
            printf 'no\n' > "$dir/ufw.active"
        fi
        active fail2ban.service > "$dir/fail2ban.active" || return
        enabled fail2ban.service > "$dir/fail2ban.enabled" || return
        for unit in "${TG_UNITS[@]}"; do
            enabled "$unit" > "$dir/$unit.enabled" || return
        done
        traffic_guard_capture_runtime "$dir" || return
        ssh_context > "$dir/initiator-ssh" || return
    fi
    printf '%s\n' "$scope" > "$dir/scopes" || return
    printf '%s\n' "${dir##*/}"
}

restore_service() {
    local unit=$1 was_active=$2 was_enabled=$3 errors=0
    if [[ $was_enabled == yes ]]; then
        systemctl enable "$unit" || errors=1
    elif [[ $(enabled "$unit") == yes ]]; then
        systemctl disable "$unit" || errors=1
    fi
    if [[ $was_active == yes ]]; then
        systemctl restart "$unit" || errors=1
    elif [[ $(active "$unit") == yes ]]; then
        systemctl stop "$unit" || errors=1
    fi
    return "$errors"
}

restore_step() {
    local description=$1
    shift
    if "$@"; then return 0; fi
    warn "Не удалось восстановить $description."
    return 1
}

restore_selfsteal_files() {
    local dir=$1 unit name keep_active keep_enabled errors=0 restore_nginx=no
    if [[ -r $dir/nginx.active ]] || _selfsteal_nginx_owned_config; then
        restore_nginx=yes
        for unit in remna-node-setup-certbot.timer remna-node-setup-certbot.service; do
            if [[ $(active "$unit") == yes ]]; then systemctl stop "$unit" || errors=1; fi
        done
    fi
    for unit in "${SELFSTEAL_UNITS[@]}"; do
        name=${unit%.*}
        keep_active=no
        keep_enabled=no
        if [[ -r $dir/$name.active ]]; then
            keep_active=$(< "$dir/$name.active")
            keep_enabled=$(< "$dir/$name.enabled")
        elif [[ $restore_nginx != yes || $unit == caddy.service ]]; then
            continue
        fi
        if [[ $keep_active != yes && $(active "$unit") == yes ]]; then
            systemctl stop "$unit" || errors=1
        fi
        if [[ $keep_enabled != yes && $(enabled "$unit") == yes ]]; then
            systemctl disable "$unit" || errors=1
        fi
    done
    path_restore "$dir" "${SNAPSHOT_CADDY[@]}" || errors=1
    if [[ $restore_nginx == yes ]]; then
        path_restore "$dir" "${SNAPSHOT_NGINX[@]}" || errors=1
        systemctl daemon-reload || errors=1
    fi
    return "$errors"
}

restore_selfsteal_runtime() {
    local dir=$1 unit name errors=0
    for unit in "${SELFSTEAL_UNITS[@]}"; do
        name=${unit%.*}
        if [[ -r $dir/$name.active ]]; then
            restore_service "$unit" "$(< "$dir/$name.active")" "$(< "$dir/$name.enabled")" || errors=1
        fi
    done
    return "$errors"
}

restore_network() {
    local dir=$1 unit errors=0
    if [[ $(active fail2ban.service) == yes ]]; then systemctl stop fail2ban.service || errors=1; fi
    for unit in "${TG_UNITS[@]}"; do
        if [[ $(active "$unit") == yes ]]; then systemctl stop "$unit" || errors=1; fi
        if [[ $(enabled "$unit") == yes ]]; then systemctl disable "$unit" || errors=1; fi
    done
    path_restore "$dir" "${SNAPSHOT_NETWORK[@]}" || return
    systemctl daemon-reload || errors=1
    restore_step 'наборы TrafficGuard' traffic_guard_restore_before_ufw "$dir" || errors=1
    if [[ $(< "$dir/ufw.active") == yes ]]; then
        if LC_ALL=C ufw status | grep -q '^Status: active'; then
            ufw reload || errors=1
        else
            ufw --force enable || errors=1
        fi
    else
        ufw --force disable || errors=1
    fi
    restore_step 'цепочки TrafficGuard' traffic_guard_restore_after_ufw "$dir" || errors=1
    for unit in "${TG_UNITS[@]}"; do
        if [[ $(< "$dir/$unit.enabled") == yes ]]; then systemctl enable "$unit" || errors=1; fi
    done
    restore_step 'Fail2Ban' restore_service fail2ban.service "$(< "$dir/fail2ban.active")" "$(< "$dir/fail2ban.enabled")" || errors=1
    return "$errors"
}

restore_snapshot() {
    local id=$1 scope=$2 dir=$BACKUP_DIR/$1 errors=0
    if ! valid_snapshot_id "$id" || [[ ! -r $dir/scopes ]]; then
        fail 'Снимок не найден или неполон.'
        return 1
    fi
    if has_scope "$scope" config; then path_restore "$dir" "${SNAPSHOT_CONFIG[@]}" || errors=1; fi
    # Close new listeners before restoring the older firewall if they did not exist in the snapshot.
    if has_scope "$scope" node; then
        path_restore "$dir" "${SNAPSHOT_NODE[@]}" || errors=1
        if [[ ! -f $NODE_DIR/compose.yaml ]]; then node_restore_runtime || errors=1; fi
    fi
    if has_scope "$scope" selfsteal; then
        restore_step 'конфигурацию self-steal' restore_selfsteal_files "$dir" || errors=1
    fi
    if has_scope "$scope" network; then restore_step 'сетевые правила' restore_network "$dir" || errors=1; fi
    if has_scope "$scope" selfsteal; then
        restore_step 'сервисы self-steal' restore_selfsteal_runtime "$dir" || errors=1
    fi
    if has_scope "$scope" node && [[ -f $NODE_DIR/compose.yaml ]]; then
        restore_step 'контейнер ноды' node_restore_runtime || errors=1
    fi
    if has_scope "$scope" bbr; then
        path_restore "$dir" "${SNAPSHOT_BBR[@]}" || errors=1
        if [[ -s $dir/qdisc && $(sysctl -n net.core.default_qdisc 2>/dev/null) != "$(< "$dir/qdisc")" ]]; then
            restore_step qdisc sysctl -qw "net.core.default_qdisc=$(< "$dir/qdisc")" || errors=1
        fi
        if [[ -s $dir/cc && $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) != "$(< "$dir/cc")" ]]; then
            restore_step BBR sysctl -qw "net.ipv4.tcp_congestion_control=$(< "$dir/cc")" || errors=1
        fi
    fi
    return "$errors"
}

pending_id() {
    if [[ -r $PENDING_FILE ]]; then cat -- "$PENDING_FILE"; fi
}

arm_rollback() {
    local id=$1 unit_dir=/etc/systemd/system
    local manager=/usr/local/bin/remna-node-setup
    [[ -x $manager ]] || { fail 'Сначала установите скрипт через install.sh.'; return 1; }
    printf '%s\n' "$id" > "$PENDING_FILE" || return
    cat > "$unit_dir/$ROLLBACK_UNIT.service" <<UNIT || return
[Unit]
Description=Remna Node Setup network rollback
[Service]
Type=oneshot
ExecStart=$manager __network-timeout $id
TimeoutStartSec=infinity
Restart=on-failure
RestartSec=30s
UNIT
    cat > "$unit_dir/$ROLLBACK_UNIT.timer" <<UNIT || return
[Unit]
Description=Revert unconfirmed Remna Node Setup network configuration
[Timer]
OnActiveSec=10min
AccuracySec=1s
Unit=$ROLLBACK_UNIT.service
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload && systemctl enable --now "$ROLLBACK_UNIT.timer"
}

network_rollback_remaining() {
    local unit path deadline now
    local path_pattern='^o "(/org/freedesktop/systemd1/unit/[A-Za-z0-9_]+)"$'
    unit=$(busctl --system --timeout=2s call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
        org.freedesktop.systemd1.Manager GetUnit s "$ROLLBACK_UNIT.timer" 2>/dev/null) || return
    [[ $unit =~ $path_pattern ]] || return 1
    path=${BASH_REMATCH[1]}
    deadline=$(busctl --system --timeout=2s get-property org.freedesktop.systemd1 "$path" \
        org.freedesktop.systemd1.Timer NextElapseUSecMonotonic 2>/dev/null) || return
    [[ $deadline =~ ^t\ (0|[1-9][0-9]{0,17})$ ]] || return 1
    deadline=${BASH_REMATCH[1]}
    now=$(python3 -c 'import time; print(time.monotonic_ns() // 1000)' 2>/dev/null) || return
    if (( deadline > now )); then
        printf '%s\n' "$(((deadline - now + 999999) / 1000000))"
    else
        printf '0\n'
    fi
}

disarm_rollback() {
    local dir=/etc/systemd/system
    if [[ -e $dir/$ROLLBACK_UNIT.timer ]]; then systemctl disable --now "$ROLLBACK_UNIT.timer" || return; fi
    rm -f -- "$PENDING_FILE" "$dir/$ROLLBACK_UNIT.timer" "$dir/$ROLLBACK_UNIT.service" || return
    systemctl daemon-reload
}

rollback_pending() {
    local requested=${1:-} id scope
    id=$(pending_id) || return
    if [[ -z $id || ( -n $requested && $id != "$requested" ) ]]; then return 0; fi
    if ! valid_snapshot_id "$id" || [[ ! -r $BACKUP_DIR/$id/scopes ]]; then
        fail 'Повреждён идентификатор отката.'
        return 1
    fi
    scope=$(< "$BACKUP_DIR/$id/scopes")
    info "Восстанавливаю снимок $id."
    restore_snapshot "$id" "$scope" || { fail "Откат не завершён. Снимок сохранён в $BACKUP_DIR/$id."; return 1; }
    disarm_rollback
}

confirm_network() {
    local id original current
    id=$(pending_id) || return
    valid_snapshot_id "$id" || { fail 'Нет сетевых изменений для подтверждения.'; return 1; }
    original=$(< "$BACKUP_DIR/$id/initiator-ssh")
    if [[ -n $original ]]; then
        current=$(ssh_context)
        if [[ -z $current || $current == "$original" ]]; then
            fail 'Откройте новое подключение по SSH и повторите sudo remna-node-setup confirm.'
            return 1
        fi
    fi
    disarm_rollback || return
    info 'Сетевые настройки подтверждены.'
}

finish_change() {
    local result=$1 scope=$2 id=$3 changed=$4 committed=$5
    trap - EXIT
    if [[ $changed == yes && $committed == no ]]; then
        warn 'Операция прервана. Восстанавливаю конфигурацию.'
        if restore_snapshot "$id" "$scope"; then
            if has_scope "$scope" network; then disarm_rollback || result=1; fi
        else
            warn "Не все настройки удалось восстановить. Снимок $id сохранён."
        fi
    fi
    exit "$result"
}

run_change() (
    local scope=$1 id changed=no committed=no
    shift
    id=$(capture_snapshot "$scope") || return
    info "Снимок $id."
    trap 'finish_change "$?" "$scope" "$id" "$changed" "$committed"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if has_scope "$scope" network && ! arm_rollback "$id"; then
        disarm_rollback || warn 'Проверьте состояние таймера отката.'
        fail 'Не удалось запустить таймер отката. Изменения не применены.'
        return 1
    fi
    changed=yes
    "$@" || return
    committed=yes
    if has_scope "$scope" network; then
        ui_network_confirmation
    fi
)
