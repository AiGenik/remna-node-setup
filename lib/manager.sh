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
    local saved_port=${1:-} connection port
    connection=$(ssh_context)
    port=${connection##* }
    if [[ -n ${ADMIN_IP:-} ]] && valid_port "$port"; then
        printf '%s\n' "$port"
    elif valid_port "$saved_port"; then
        printf '%s\n' "$saved_port"
    elif command -v sshd >/dev/null; then
        (sshd -T 2>/dev/null || :) | awk '$1 == "port" && !seen++ { print $2 }'
    fi
}

ask_secret() {
    local answer
    while true; do
        if [[ -s $NODE_SECRET ]]; then
            printf '  SECRET_KEY из панели [Enter сохраняет текущий] → ' >&2
        else
            printf '  SECRET_KEY из панели → ' >&2
        fi
        IFS= read -rs answer || return
        printf '\n' >&2
        answer=$(compose_value "$answer" SECRET_KEY) || return
        if [[ $answer != *[[:space:]]* && ( -n $answer || -s $NODE_SECRET ) ]]; then
            # shellcheck disable=SC2034 # Used by save_secret in common.sh.
            NEW_NODE_SECRET=$answer
            return 0
        fi
        warn 'Вставьте ключ или строку SECRET_KEY из конфигурации.'
        if [[ $UI_INTERACTIVE != yes ]]; then return 1; fi
    done
}

wizard_input() {
    local label=$1 default=$2 check=$3 answer
    shift 3
    while answer=$(prompt "  $label →" "$default"); do
        if "$check" "$answer" "$@"; then return 0; fi
        if [[ $UI_INTERACTIVE != yes ]]; then return 1; fi
    done
    return 1
}

check_node_domain() {
    local domain=${1,,}
    domain=${domain%.}
    valid_domain "$domain" || { fail 'Введите поддомен как node.example.com.'; return 1; }
    printf '%s\n' "$domain"
}

check_node_port() {
    local port
    port=$(compose_value "$1" NODE_PORT) || return
    valid_port "$port" || { fail 'Введите число от 1 до 65535 или строку NODE_PORT из панели.'; return 1; }
    printf '%s\n' "$port"
}

check_panel_ips() {
    local addresses
    addresses=$(normalize_ips "$1") || return
    [[ -n $addresses ]] || { fail 'Укажите хотя бы один исходящий IP панели.'; return 1; }
    printf '%s\n' "$addresses"
}

check_ssh_port() {
    local port=$1 expected=$2
    valid_port "$port" || { fail 'Введите номер текущего порта SSH.'; return 1; }
    if [[ -n $ADMIN_IP && -n $expected && $port != "$expected" ]]; then
        fail "Текущий SSH-сеанс использует порт $expected. Укажите его или нажмите Enter."
        return 1
    fi
    printf '%s\n' "$port"
}

show_panel_help() {
    info "В панели Remnawave адрес ноды — $NODE_DOMAIN, служебный порт — $NODE_PORT."
    info 'Если карточка создания открыта, нажмите «Далее», выберите профиль и нажмите «Создать».'
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
    local scope='config network node' continue_apply detected_port
    local components='UFW, Fail2Ban'
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

    ui_step 1 'Домен ноды'
    info '  В кабинете хостинга найдите публичный IPv4 этого VPS.'
    info '  У DNS-провайдера создайте A-запись и укажите в ней этот IP.'
    info '  Пример поддомена для ноды — node.example.com.'
    info '  Для self-steal в Cloudflare выберите режим DNS only.'
    printf '\n'
    NODE_DOMAIN=$(wizard_input 'Поддомен ноды' "$old_domain" check_node_domain) || return

    ui_step 2 'Служебный порт ноды'
    info '  В панели Remnawave откройте Ноды → Управление (Nodes → Management) → +.'
    info "  В поле «Домен или IP» введите $NODE_DOMAIN."
    info '  Возьмите номер из Node Port или скопируйте docker-compose.yml.'
    info '  В блоке environment найдите строку NODE_PORT=2222.'
    info '  По этому порту панель управляет нодой. Вставьте число или всю строку.'
    printf '\n'
    NODE_PORT=$(wizard_input 'NODE_PORT из панели' "$old_port" check_node_port) || return

    ui_step 3 'Исходящий IP панели'
    info '  Откройте SSH на сервере, где установлена панель Remnawave.'
    info '  Посмотрите, с какого публичного IPv4 этот сервер выходит в сеть.'
    info '  curl -4fsS https://api.ipify.org && echo'
    info '  Вставьте полученный IP сюда. Несколько адресов введите через пробел.'
    printf '\n'
    PANEL_IPS=$(wizard_input 'IP панели' "$old_panel" check_panel_ips) || return

    ui_step 4 'Доступ по SSH'
    detected_port=$(detect_ssh_port "$old_ssh") || return
    info '  Укажите порт, по которому подключились к этому VPS. Обычно это 22.'
    SSH_PORT=$(wizard_input 'SSH-порт VPS' "${detected_port:-22}" check_ssh_port "$detected_port") || return
    printf '\n'
    info '  Доверенный IP — адрес, с которого вы подключаетесь по SSH.'
    info '  Fail2Ban пропускает доверенные адреса.'
    info '  TrafficGuard проверяет, что их нет в списке блокировки.'
    if [[ -n $ADMIN_IP ]]; then
        info "  IP текущего SSH-сеанса — $ADMIN_IP. Enter оставит показанное значение."
    else
        info '  Введите свой публичный IP. Для TrafficGuard он нужен обязательно.'
    fi
    ADMIN_IPS=$(wizard_input 'Доверенные IP или подсети' "${old_admin:-$ADMIN_IP}" normalize_ips network) || return

    ui_step 5 'Дополнительные компоненты'
    ENABLE_SELFSTEAL=$old_selfsteal
    if [[ $ENABLE_SELFSTEAL == no ]]; then
        info '  Self-steal на Caddy — локальный HTTPS-сайт для VLESS REALITY.'
        ENABLE_SELFSTEAL=$(yes_no '  Установить self-steal?' y) || return
    fi
    ENABLE_BBR=$old_bbr
    if [[ $ENABLE_BBR == no ]]; then
        info '  BBR и fq — настройки передачи TCP, если их поддерживает ядро.'
        ENABLE_BBR=$(yes_no '  Включить BBR и fq?' y) || return
    fi
    ENABLE_TRAFFIC_GUARD=$old_traffic
    if [[ $ENABLE_TRAFFIC_GUARD == no ]]; then
        info '  TrafficGuard блокирует адреса из списка известных сканеров.'
        ENABLE_TRAFFIC_GUARD=$(yes_no '  Включить TrafficGuard?' n) || return
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

    ui_step 6 'Ключ подключения ноды'
    info '  Вверху карточки ноды скопируйте значение Secret Key (SECRET_KEY).'
    info '  Можно также вставить строку SECRET_KEY из блока environment'
    info '  в файле, который выдаёт «Скопировать docker-compose.yml».'
    info '  Ввод скрыт. После вставки нажмите Enter.'
    printf '\n'
    ask_secret || return

    ui_step 7 'Проверка перед установкой'
    printf '  %s\n' "Нода             $NODE_DOMAIN" "Панель           $PANEL_IPS" \
        "Порт для панели  TCP $NODE_PORT" "Доступ по SSH    TCP $SSH_PORT" 'Доступ к VPN     TCP 443'
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        info '  Сертификат       TCP 80'
        components+=', self-steal'
    fi
    if [[ $ENABLE_BBR == yes ]]; then components+=', BBR'; fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then components+=', TrafficGuard'; fi
    info "  Компоненты       $components"
    printf '\n'
    info '  Служебный порт откроется только для указанных IP панели.'
    info '  После установки откройте второе SSH-подключение.'
    info '  В нём выполните sudo remna-node-setup confirm.'
    continue_apply=$(yes_no '  Начать установку?' n) || return
    [[ $continue_apply == yes ]] || { info 'Установка отменена.'; return 0; }
    ui_screen 'Установка ноды  /  Применение настроек'
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
