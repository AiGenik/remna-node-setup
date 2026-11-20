#!/usr/bin/env bash

get_admin_ip() {
    local connection source
    connection=$(ssh_context) || return
    source=${connection%% *}
    ADMIN_IP=$(normalize_ips "$source" 2>/dev/null) || ADMIN_IP=
}

require_config() {
    load_config || { fail 'Сначала запустите мастер установки.'; return 1; }
    get_admin_ip
}

require_no_pending() {
    if [[ -n $(pending_id) ]]; then
        fail 'Сначала подтвердите или отмените предыдущие сетевые изменения.'
        return 1
    fi
}

prepare_security() {
    local had_fail2ban=no
    if command -v fail2ban-client >/dev/null; then had_fail2ban=yes; fi
    apt_install_missing ufw fail2ban python3-systemd ipset iptables || return
    if [[ $had_fail2ban == no ]]; then systemctl disable --now fail2ban.service || return; fi
}

detect_ssh_port() {
    local connection port
    connection=$(ssh_context)
    port=${connection##* }
    if valid_port "$port"; then
        printf '%s\n' "$port"
    elif command -v sshd >/dev/null; then
        (sshd -T 2>/dev/null || :) | awk '$1 == "port" && !seen++ { print $2 }'
    fi
}

ask_secret() {
    local answer
    if [[ -s $NODE_SECRET ]]; then
        printf 'SECRET_KEY из панели [Enter сохраняет текущий] ' >&2
    else
        printf 'SECRET_KEY из панели ' >&2
    fi
    IFS= read -rs answer || return
    printf '\n' >&2
    if [[ $answer == *$'\r'* || ( -z $answer && ! -s $NODE_SECRET ) ]]; then
        fail 'Введите ключ из панели одной строкой.'
        return 1
    fi
    # shellcheck disable=SC2034 # Used by save_secret in common.sh.
    NEW_NODE_SECRET=$answer
}

show_panel_help() {
    info "В панели Remnawave адрес ноды — $NODE_DOMAIN, служебный порт — $NODE_PORT."
    if [[ $ENABLE_SELFSTEAL == yes ]]; then selfsteal_panel_help; fi
    info 'Проверьте статус ноды и подключение тестового клиента в панели.'
}

apply_installation() {
    save_config && save_secret && security_apply || return
    node_apply || return
    if [[ $ENABLE_SELFSTEAL == yes ]]; then selfsteal_apply || return; fi
    if [[ $ENABLE_BBR == yes ]]; then bbr_apply || return; fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_apply || return; fi
    show_panel_help
}

install_wizard() {
    local scope='config network node' raw port continue_apply detected_port
    local old_domain='' old_panel='' old_port=2222 old_admin='' old_ssh='' old_selfsteal=no old_bbr=no old_traffic=no
    apt_install_missing ca-certificates curl python3 iproute2 || return
    get_admin_ip || return

    if load_config; then
        old_domain=$NODE_DOMAIN
        old_port=$NODE_PORT
        old_panel=$PANEL_IPS
        old_ssh=$SSH_PORT
        old_admin=$ADMIN_IPS
        old_selfsteal=$ENABLE_SELFSTEAL
        old_bbr=$ENABLE_BBR
        old_traffic=$ENABLE_TRAFFIC_GUARD
    fi

    info 'В панели Remnawave откройте Nodes → Management и добавьте ноду.'
    info 'Из сгенерированного Compose понадобятся NODE_PORT и SECRET_KEY.'
    NODE_DOMAIN=$(prompt 'Домен ноды' "$old_domain") || return
    NODE_DOMAIN=${NODE_DOMAIN,,}
    NODE_DOMAIN=${NODE_DOMAIN%.}
    valid_domain "$NODE_DOMAIN" || { fail 'Укажите полное доменное имя ноды.'; return 1; }
    port=$(prompt 'Служебный порт ноды из панели' "$old_port") || return
    valid_port "$port" || { fail 'Некорректный порт ноды.'; return 1; }
    NODE_PORT=$port
    raw=$(prompt 'Исходящие IP панели через пробел' "$old_panel") || return
    PANEL_IPS=$(normalize_ips "$raw") || return
    [[ -n $PANEL_IPS ]] || { fail 'Укажите хотя бы один IP панели.'; return 1; }
    detected_port=$(detect_ssh_port) || return
    port=$(prompt 'Действующий SSH-порт VPS' "${detected_port:-${old_ssh:-22}}") || return
    valid_port "$port" || { fail 'Некорректный порт SSH.'; return 1; }
    if [[ -n $ADMIN_IP && -n $detected_port && $port != "$detected_port" ]]; then
        fail "Текущая SSH-сессия использует порт $detected_port."
        return 1
    fi
    SSH_PORT=$port
    raw=$(prompt 'Доверенные IP или подсети администратора для Fail2Ban и TrafficGuard' "${old_admin:-$ADMIN_IP}") || return
    ADMIN_IPS=$(normalize_ips "$raw" network) || return

    ENABLE_SELFSTEAL=$old_selfsteal
    if [[ $ENABLE_SELFSTEAL == no ]]; then
        ENABLE_SELFSTEAL=$(yes_no 'Добавить self-steal с Caddy?' y) || return
    fi
    ENABLE_BBR=$old_bbr
    if [[ $ENABLE_BBR == no ]]; then ENABLE_BBR=$(yes_no 'Включить BBR и fq?' y) || return; fi
    ENABLE_TRAFFIC_GUARD=$old_traffic
    if [[ $ENABLE_TRAFFIC_GUARD == no ]]; then
        ENABLE_TRAFFIC_GUARD=$(yes_no 'Добавить TrafficGuard со списком известных сканеров?' n) || return
    fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes && -z ${ADMIN_IP:-}${ADMIN_IPS:-} ]]; then
        fail 'Для TrafficGuard укажите доверенный IP или подсеть администратора.'
        return 1
    fi

    security_preflight && node_preflight || return
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_preflight || return
        scope+=' selfsteal'
    fi
    if [[ $ENABLE_BBR == yes ]]; then scope+=' bbr'; fi
    ask_secret || return
    info "UFW разрешит SSH TCP $SSH_PORT, VPN TCP 443 и служебный TCP $NODE_PORT только от панели."
    if [[ $ENABLE_SELFSTEAL == yes ]]; then info 'Caddy дополнительно использует публичный TCP 80.'; fi
    continue_apply=$(yes_no 'Применить настройки?' n) || return
    [[ $continue_apply == yes ]] || { info 'Установка отменена.'; return 0; }
    node_prepare_image && prepare_security || return
    run_change "$scope" apply_installation
}

apply_selfsteal() {
    save_config && security_apply && selfsteal_apply && show_panel_help
}

add_selfsteal() {
    require_config || return
    ENABLE_SELFSTEAL=yes
    selfsteal_preflight && security_preflight && prepare_security || return
    run_change 'config network selfsteal' apply_selfsteal
}

configure_security() {
    require_config && security_preflight && prepare_security || return
    run_change network security_apply
}

apply_bbr() {
    save_config && bbr_apply
}

configure_bbr() {
    require_config || return
    ENABLE_BBR=yes
    run_change 'config bbr' apply_bbr
}

apply_traffic_guard() {
    save_config && traffic_guard_apply
}

configure_traffic_guard() {
    local consent
    require_config || return
    [[ -n ${ADMIN_IP:-}${ADMIN_IPS:-} ]] || { fail 'Укажите доверенный адрес при запуске мастера.'; return 1; }
    security_ufw_active || { fail 'Сначала включите UFW через пункт «Защита».'; return 1; }
    consent=$(yes_no 'Применить список блокировки известных сканеров из текущего релиза?' n) || return
    [[ $consent == yes ]] || return 0
    ENABLE_TRAFFIC_GUARD=yes
    run_change 'config network' apply_traffic_guard
}

update_node() {
    require_config || return
    security_ufw_active || { fail 'Сначала включите UFW через пункт «Защита».'; return 1; }
    node_preflight && node_prepare_image || return
    run_change node node_apply
}

backup_scope() {
    local scope='config node network'
    if [[ $ENABLE_SELFSTEAL == yes ]]; then scope+=' selfsteal'; fi
    if [[ $ENABLE_BBR == yes ]]; then scope+=' bbr'; fi
    printf '%s\n' "$scope"
}

create_backup() {
    local id scope
    require_config || return
    scope=$(backup_scope) || return
    id=$(capture_snapshot "$scope") || return
    info "Снимок сохранён в $BACKUP_DIR/$id."
}

do_restore() {
    local id=$1 scope
    if ! valid_snapshot_id "$id" || [[ ! -r $BACKUP_DIR/$id/scopes ]]; then
        fail 'Снимок не найден.'
        return 1
    fi
    scope=$(< "$BACKUP_DIR/$id/scopes")
    run_change "$scope" restore_snapshot "$id" "$scope"
}

status_all() {
    local id
    id=$(pending_id) || return
    if [[ -n $id ]]; then info "Ожидается подтверждение SSH. Снимок $id."; fi
    if ! load_config; then
        node_status || :
        info 'Настройте узел через пункт «Установить ноду».'
        return 0
    fi
    node_status || :
    if [[ $ENABLE_SELFSTEAL == yes ]]; then selfsteal_status || :; fi
    security_status
    bbr_status
    traffic_guard_status
}

doctor() {
    local result=0
    require_config || return
    node_status || result=1
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_status || result=1
        if ! ss -H -ltn 'sport = :443' | grep -q .; then
            warn 'TCP 443 пока не слушает. Примените профиль Xray в панели.'
            result=1
        fi
    fi
    if ! security_ufw_active; then warn 'UFW неактивен.'; result=1; fi
    if ! fail2ban-client status sshd >/dev/null 2>&1; then warn 'Fail2Ban для SSH недоступен.'; result=1; fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status || result=1; fi
    bbr_status
    df -h -- "$NODE_DIR" "$BACKUP_DIR"
    return "$result"
}

dispatch() (
    local action=${1-} target=${2-}
    case "$action" in
        status) [[ $# == 1 ]] || return 2; status_all; return ;;
        doctor) [[ $# == 1 ]] || return 2; doctor; return ;;
        logs) [[ $# == 1 ]] || return 2; node_logs; return ;;
    esac
    release_acquire_lock || return
    case "$action" in
        confirm) [[ $# == 1 ]] || return 2; confirm_network; return ;;
        rollback)
            if [[ $# == 1 ]]; then rollback_pending; return; fi
            if [[ $# != 2 || $target != tool ]]; then usage >&2; return 2; fi
            ;;
    esac
    require_no_pending || return
    case "$action" in
        install) [[ $# == 1 ]] || return 2; install_wizard ;;
        selfsteal) [[ $# == 1 ]] || return 2; add_selfsteal ;;
        security) [[ $# == 1 ]] || return 2; configure_security ;;
        bbr) [[ $# == 1 ]] || return 2; configure_bbr ;;
        backup) [[ $# == 1 ]] || return 2; create_backup ;;
        restore) [[ $# == 2 ]] || return 2; do_restore "$target" ;;
        rollback) release_rollback ;;
        update)
            case "$target" in
                tool) [[ $# -le 3 ]] || return 2; release_update "${3-}" ;;
                node) [[ $# == 2 ]] || return 2; update_node ;;
                traffic-guard) [[ $# == 2 ]] || return 2; configure_traffic_guard ;;
                *) usage >&2; return 2 ;;
            esac ;;
        *) usage >&2; return 2 ;;
    esac
)

MENU_ACTIONS=(
    'Установить ноду и компоненты|install'
    'Добавить self-steal|selfsteal'
    'UFW и Fail2Ban|security'
    'Включить BBR и fq|bbr'
    'Включить или обновить TrafficGuard|update traffic-guard'
    'Статус|status'
    'Диагностика|doctor'
    'Логи ноды|logs'
    'Сохранить снимок|backup'
    'Восстановить снимок|restore'
    'Обновить скрипт|update tool'
    'Обновить ноду|update node'
    'Откатить версию скрипта|rollback tool'
    'Откатить ожидающие сетевые изменения|rollback'
    'Подтвердить сетевые настройки|confirm'
)

show_menu() {
    local index choice line id
    local -a command=()
    while true; do
        info "Remna Node Setup $(version_get version)"
        index=0
        for line in "${MENU_ACTIONS[@]}"; do
            ((index += 1))
            printf '%2d. %s\n' "$index" "${line%%|*}"
        done
        info ' 0. Выйти'
        choice=$(prompt 'Выберите пункт') || return 0
        if [[ $choice == 0 ]]; then return 0; fi
        if [[ ! $choice =~ ^[1-9][0-9]?$ ]] || (( choice > ${#MENU_ACTIONS[@]} )); then
            warn 'Нет такого пункта.'
            continue
        fi
        line=${MENU_ACTIONS[choice-1]}
        read -r -a command <<< "${line#*|}"
        if [[ ${command[0]} == restore ]]; then
            find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r
            id=$(prompt 'Идентификатор снимка') || return 0
            command+=("$id")
        fi
        dispatch "${command[@]}" || warn 'Команда завершилась с ошибкой.'
        if [[ ${command[*]} == 'update tool' || ${command[*]} == 'rollback tool' ]]; then
            info 'Откройте меню снова, чтобы использовать выбранную версию.'
            return
        fi
        printf '\n'
    done
}
