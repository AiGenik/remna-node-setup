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
    ui_run 'Пакеты защиты' apt_install_missing ufw fail2ban python3-systemd ipset iptables || return
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
    local answer prompt='  SECRET_KEY из панели → '
    if [[ -s $NODE_SECRET ]]; then
        prompt='  SECRET_KEY [Enter — оставить текущий] → '
    fi
    while true; do
        if [[ -t 0 && -t 2 ]]; then
            answer=$(python3 "$PROJECT_DIR/lib/secret-input.py" "$UI_BOLD$prompt$UI_RESET" "$UI_CLEAR") || return
        else
            printf '%s' "$prompt" >&2
            IFS= read -r answer || return
            printf '\n' >&2
        fi
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
    local mode=$1
    save_config && save_secret && ui_run 'UFW и Fail2Ban' security_apply || return
    ui_run 'Контейнер Remnawave' node_apply || return
    if [[ $mode == full ]]; then
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            ui_run "HTTPS и сертификат ($SELFSTEAL_SERVER)" selfsteal_apply || return
        fi
        if [[ $ENABLE_BBR == yes ]]; then bbr_apply || return; fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then ui_run 'Список TrafficGuard' traffic_guard_apply || return; fi
    fi
    rm -f -- "$CONFIG_DIR/host.json" || return
    show_panel_help
}

wizard_selfsteal_preflight() {
    local previous=$1 choice
    while ! selfsteal_preflight; do
        if [[ $UI_INTERACTIVE != yes ]]; then return 1; fi
        printf '\n'
        info '  1  Повторить проверку'
        info '  2  Изменить домен'
        if [[ $previous != yes ]]; then info '  3  Установить ноду без self-steal'; fi
        info '  0  Отменить установку'
        while true; do
            choice=$(prompt '  Действие →' '1') || return
            case "$choice" in
                0) info 'Установка отменена.'; return 2 ;;
                1) break ;;
                2)
                    NODE_DOMAIN=$(wizard_input 'Поддомен ноды' "$NODE_DOMAIN" check_node_domain) || return
                    info "  Укажите $NODE_DOMAIN также в карточке ноды Remnawave."
                    break
                    ;;
                3)
                    if [[ $previous != yes ]]; then
                        ENABLE_SELFSTEAL=no
                        return 0
                    fi
                    ;;
            esac
            warn 'Выберите действие из списка.'
        done
    done
}

install_wizard() {
    local mode=${1:-full} scope='config network node' continue_apply detected_port result=0
    local steps=7 key_step=6 review_step=7
    local components='UFW, Fail2Ban'
    local old_domain='' old_panel='' old_port=2222 old_admin='' old_ssh='' old_selfsteal=no old_bbr=no old_traffic=no
    local old_webserver=caddy saved=no
    if [[ $mode == node-only ]]; then steps=6; key_step=5; review_step=6; fi
    apt_install_missing ca-certificates curl python3 iproute2 || return
    get_admin_ip || return

    if load_config; then
        saved=yes
    elif [[ -e $CONFIG_DIR/node.json || -L $CONFIG_DIR/node.json ]]; then
        fail 'Не удалось прочитать настройки ноды. Проверьте node.json или восстановите снимок.'
        return 1
    elif [[ -e $CONFIG_DIR/host.json || -L $CONFIG_DIR/host.json ]]; then
        load_host_settings || return
        saved=yes
    fi
    if [[ $saved == yes ]]; then
        old_domain=$NODE_DOMAIN
        old_port=${NODE_PORT:-2222}
        old_panel=$PANEL_IPS
        old_ssh=$SSH_PORT
        old_admin=$ADMIN_IPS
        old_selfsteal=$ENABLE_SELFSTEAL
        old_webserver=$SELFSTEAL_SERVER
        old_bbr=$ENABLE_BBR
        old_traffic=$ENABLE_TRAFFIC_GUARD
    fi

    ui_step 1 'Домен ноды' "$steps"
    info '  A-запись node.example.com должна указывать на IPv4 этого VPS.'
    info '  Для self-steal в Cloudflare выберите DNS only.'
    printf '\n'
    NODE_DOMAIN=$(wizard_input 'Поддомен ноды' "$old_domain" check_node_domain) || return
    if [[ $mode == node-only && $old_selfsteal == yes && $NODE_DOMAIN != "$old_domain" ]]; then
        fail "Для действующего self-steal используется $old_domain. Укажите его или смените домен через полный мастер."
        return 1
    fi

    ui_step 2 'Служебный порт ноды' "$steps"
    info '  Remnawave → Ноды → Управление → +'
    info "  В поле «Домен или IP» введите $NODE_DOMAIN."
    info '  Вставьте Node Port или строку NODE_PORT из Compose.'
    printf '\n'
    NODE_PORT=$(wizard_input 'NODE_PORT из панели' "$old_port" check_node_port) || return

    ui_step 3 'Исходящий IP панели' "$steps"
    info '  Выполните на сервере панели Remnawave'
    info '  curl -4fsS https://api.ipify.org && echo'
    info '  Вставьте полученный IP. Несколько адресов — через пробел.'
    printf '\n'
    PANEL_IPS=$(wizard_input 'IP панели' "$old_panel" check_panel_ips) || return

    ui_step 4 'Доступ по SSH' "$steps"
    detected_port=$(detect_ssh_port "$old_ssh") || return
    info '  Enter оставит предложенный порт.'
    SSH_PORT=$(wizard_input 'SSH-порт VPS' "${detected_port:-22}" check_ssh_port "$detected_port") || return
    printf '\n'
    info '  Доверенный IP — ваш адрес для SSH. Fail2Ban пропускает его.'
    ADMIN_IPS=$(wizard_input 'Доверенные IP или подсети' "${old_admin:-$ADMIN_IP}" normalize_ips network) || return

    ENABLE_SELFSTEAL=$old_selfsteal
    SELFSTEAL_SERVER=$old_webserver
    ENABLE_BBR=$old_bbr
    ENABLE_TRAFFIC_GUARD=$old_traffic
    if [[ $mode == full ]]; then
        ui_step 5 'Дополнительные компоненты' "$steps"
        if [[ $ENABLE_SELFSTEAL == no ]]; then
            ENABLE_SELFSTEAL=$(yes_no '  Self-steal — HTTPS для VLESS REALITY?' y) || return
        fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            SELFSTEAL_SERVER=$(select_selfsteal_server "$old_webserver") || return
            wizard_selfsteal_preflight "$old_selfsteal" || result=$?
            if (( result == 2 )); then return 0; fi
            if (( result != 0 )); then return "$result"; fi
        fi
        if [[ $ENABLE_BBR == no ]]; then
            ENABLE_BBR=$(yes_no '  BBR + fq — настройка TCP?' y) || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == no ]]; then
            ENABLE_TRAFFIC_GUARD=$(yes_no '  TrafficGuard — блокировка сканеров?' n) || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes && -z ${ADMIN_IP:-}${ADMIN_IPS:-} ]]; then
            fail 'Для TrafficGuard укажите доверенный IP или подсеть администратора.'
            return 1
        fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then scope+=' selfsteal'; fi
        if [[ $ENABLE_BBR == yes ]]; then scope+=' bbr'; fi
    fi

    security_preflight && node_preflight || return

    ui_step "$key_step" 'Ключ подключения ноды' "$steps"
    info '  Скопируйте Secret Key в карточке ноды или строку SECRET_KEY из Compose.'
    info '  Вставьте ключ. Счётчик покажет ввод. Нажмите Enter.'
    printf '\n'
    ask_secret || return

    ui_step "$review_step" 'Проверка перед установкой' "$steps"
    printf '  %s\n' "Нода             $NODE_DOMAIN" "Панель           $PANEL_IPS" \
        "Порт для панели  TCP $NODE_PORT" "Доступ по SSH    TCP $SSH_PORT" 'Доступ к VPN     TCP 443'
    if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  HTTP для ACME   TCP 80'; fi
    if [[ $mode == full ]]; then
        if [[ $ENABLE_SELFSTEAL == yes ]]; then components+=", self-steal ($SELFSTEAL_SERVER)"; fi
        if [[ $ENABLE_BBR == yes ]]; then components+=', BBR'; fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then components+=', TrafficGuard'; fi
    fi
    info "  Компоненты       $components"
    printf '\n'
    info '  Служебный порт откроется только для указанных IP панели.'
    info '  После установки откройте второе SSH-подключение.'
    info '  В нём выполните sudo remna-node-setup confirm.'
    continue_apply=$(yes_no '  Начать установку?' n) || return
    [[ $continue_apply == yes ]] || { info 'Установка отменена.'; return 0; }
    ui_screen 'Установка ноды  /  Применение настроек'
    ui_run 'Docker и образ ноды' node_prepare_image && prepare_security || return
    run_change "$scope" apply_installation "$mode"
}

apply_selfsteal() {
    save_config && ui_run 'Правила доступа' security_apply &&
        ui_run "HTTPS и сертификат ($SELFSTEAL_SERVER)" selfsteal_apply && show_panel_help
}

add_selfsteal() {
    require_config || return
    ENABLE_SELFSTEAL=yes
    SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER" "${1-}") || return
    selfsteal_preflight && security_preflight && prepare_security || return
    run_change 'config network selfsteal' apply_selfsteal
}

configure_security() {
    require_config && security_preflight && prepare_security || return
    run_change network ui_run 'UFW и Fail2Ban' security_apply
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
    save_config && ui_run 'Список TrafficGuard' traffic_guard_apply
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
    local scope='config'
    if [[ -n $NODE_PORT ]]; then scope+=' node'; fi
    if command -v ufw >/dev/null; then scope+=' network'; fi
    if [[ $ENABLE_SELFSTEAL == yes ]]; then scope+=' selfsteal'; fi
    if [[ $ENABLE_BBR == yes ]]; then scope+=' bbr'; fi
    printf '%s\n' "$scope"
}

create_backup() {
    local id scope
    if ! load_config && ! load_host_settings; then
        fail 'Сначала настройте ноду или один из компонентов.'
        return 1
    fi
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
    if ! load_config && ! load_host_settings; then
        node_status || :
        info 'Начните с мастера или выберите отдельный компонент.'
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
    if ! load_config && ! load_host_settings; then
        fail 'Сначала настройте ноду или один из компонентов.'
        return 1
    fi
    node_status || result=1
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_status || result=1
        if [[ -n $NODE_PORT ]] && ! ss -H -ltn 'sport = :443' | grep -q .; then
            warn 'TCP 443 пока не слушает. Примените профиль Xray в панели.'
            result=1
        fi
    fi
    if [[ -n $SSH_PORT ]]; then
        if ! security_ufw_active; then warn 'UFW неактивен.'; result=1; fi
        if ! fail2ban-client status sshd >/dev/null 2>&1; then warn 'Fail2Ban для SSH недоступен.'; result=1; fi
    fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status || result=1; fi
    bbr_status
    df -h -- "$STATE_DIR" "$BACKUP_DIR"
    return "$result"
}

check_dns() {
    local domain=$1
    if [[ -z $domain ]]; then
        if load_config || load_host_settings; then domain=$NODE_DOMAIN; fi
        if [[ $UI_INTERACTIVE == yes ]]; then
            domain=$(wizard_input 'Поддомен ноды' "$domain" check_node_domain) || return
        fi
    fi
    NODE_DOMAIN=$(check_node_domain "$domain") || return
    _selfsteal_validate_domain report
}

dispatch() (
    local action=${1-} target=${2-}
    case "$action" in
        status) [[ $# == 1 ]] || return 2; status_all; return ;;
        doctor) [[ $# == 1 ]] || return 2; doctor; return ;;
        dns) [[ $# -le 2 ]] || return 2; check_dns "$target"; return ;;
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
        install)
            [[ $# == 1 || ( $# == 2 && $target == node-only ) ]] || return 2
            install_wizard "$target"
            ;;
        selfsteal)
            [[ $# -le 2 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then add_selfsteal "$target"; else standalone_selfsteal "$target"; fi
            ;;
        security)
            [[ $# == 1 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then configure_security; else standalone_security; fi
            ;;
        bbr)
            [[ $# == 1 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then configure_bbr; else standalone_bbr; fi
            ;;
        backup) [[ $# == 1 ]] || return 2; create_backup ;;
        restore) [[ $# == 2 ]] || return 2; do_restore "$target" ;;
        rollback) release_rollback ;;
        update)
            case "$target" in
                tool) [[ $# -le 3 ]] || return 2; release_update "${3-}" ;;
                node) [[ $# == 2 ]] || return 2; update_node ;;
                traffic-guard)
                    [[ $# == 2 ]] || return 2
                    if [[ -e $CONFIG_DIR/node.json ]]; then configure_traffic_guard; else standalone_traffic_guard; fi
                    ;;
                *) usage >&2; return 2 ;;
            esac ;;
        *) usage >&2; return 2 ;;
    esac
)
