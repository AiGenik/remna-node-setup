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

check_node_address() {
    local address=${1,,} ip
    address=${address%.}
    if valid_domain "$address"; then
        printf '%s\n' "$address"
    elif ip=$(normalize_ips "$address" 2>/dev/null) && [[ -n $ip && $ip != *' '* ]]; then
        printf '%s\n' "$ip"
    else
        fail 'Введите домен или публичный IP этого VPS.'
    fi
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

ask_panel_ips() {
    info '  На сервере панели выполните curl -4fsS https://api.ipify.org && echo' >&2
    wizard_input 'IP панели' "$1" check_panel_ips
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
    printf '\n'
    ui_section 'Завершите в Remnawave'
    info "  Ноды → Управление → $NODE_DOMAIN · Node Port $NODE_PORT"
    info '  Выберите Config Profile, сохраните ноду и проверьте подключение.'
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_panel_help
    elif [[ $ENABLE_SECURITY == yes && -n $VPN_PORTS ]]; then
        info "  Порты профиля и Host должны совпадать с разрешёнными · $VPN_PORTS"
    fi
    if [[ $ENABLE_SECURITY == no || -z $PANEL_IPS ]]; then
        info "  В firewall разрешите TCP $NODE_PORT только с IP панели."
    fi
}

apply_installation() {
    local mode=$1
    save_config && save_secret || return
    if [[ $mode == full ]]; then
        ui_install_phase security_apply || return
    fi
    ui_install_phase node_apply || return
    if [[ $mode == full ]]; then
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            ui_install_phase selfsteal_apply || return
        fi
        if [[ $ENABLE_BBR == yes ]]; then
            ui_install_phase bbr_apply || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then
            ui_install_phase traffic_guard_apply || return
        fi
    fi
    rm -f -- "$CONFIG_DIR/host.json" || return
    ui_install_progress "$UI_PROGRESS_DONE"
}

wizard_selfsteal_preflight() {
    local previous=$1 choice
    while ! selfsteal_preflight; do
        if [[ $UI_INTERACTIVE != yes ]]; then return 1; fi
        printf '\n'
        info '  1  Повторить проверку'
        info '  2  Изменить домен'
        if [[ $previous != yes ]]; then info '  3  Продолжить без self-steal'; fi
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
    local mode=${1:-full} scope='config node' consent detected_port result=0
    local steps=3 components='Docker, Remnawave Node'
    local old_address='' old_port='' had_selfsteal=no has_node=no
    # shellcheck disable=SC2034 # The progress renderer reads the current wizard title.
    local UI_INSTALL_TITLE='Установка ноды'
    local UI_PROGRESS_DONE=0
    local -a UI_INSTALL_PHASES=('Docker и образ ноды')
    if [[ $mode == full ]]; then
        steps=5
        scope+=' network'
        UI_INSTALL_TITLE='Установка ноды и компонентов'
        UI_INSTALL_PHASES+=('Пакеты защиты' 'UFW и Fail2Ban')
    fi
    UI_INSTALL_PHASES+=('Контейнер Remnawave')
    ui_run 'Подготовка VPS' apt_install_missing ca-certificates curl python3 iproute2 || return

    if load_config; then
        has_node=yes
        old_port=$NODE_PORT
    elif [[ -e $CONFIG_DIR/node.json || -L $CONFIG_DIR/node.json ]]; then
        fail 'Не удалось прочитать настройки ноды. Проверьте node.json или восстановите снимок.'
        return 1
    else
        _standalone_load || return
    fi
    old_address=$NODE_DOMAIN
    had_selfsteal=$ENABLE_SELFSTEAL

    ui_step 1 'Адрес и служебный порт' "$steps"
    info '  Remnawave → Ноды → Управление → +'
    info '  Укажите одинаковый домен или IP в панели и здесь.'
    NODE_DOMAIN=$(wizard_input 'Адрес ноды' "$old_address" check_node_address) || return
    if [[ $mode == node-only && $had_selfsteal == yes && $NODE_DOMAIN != "$old_address" ]]; then
        fail "Для HTTPS используется $old_address. Чтобы сменить адрес, откройте «Нода и компоненты»."
        return 1
    fi
    info '  Node Port соединяет панель с нодой. Его можно скопировать из Compose.'
    NODE_PORT=$(wizard_input 'NODE_PORT из панели' "${old_port:-2222}" check_node_port) || return
    if [[ $mode == node-only && $ENABLE_SECURITY == yes && $has_node == yes && $NODE_PORT != "$old_port" ]]; then
        fail 'Чтобы сменить служебный порт в управляемом UFW, откройте «Нода и компоненты».'
        return 1
    fi

    ui_step 2 'Ключ подключения' "$steps"
    info '  Вставьте Secret Key из карточки ноды или строку SECRET_KEY из Compose.'
    info '  Вместо ключа при вводе виден счётчик.'
    ask_secret || return

    if [[ $mode == full ]]; then
        ui_step 3 'Дополнительные компоненты' "$steps"
        if [[ $ENABLE_SELFSTEAL == no ]]; then
            ENABLE_SELFSTEAL=$(yes_no '  Self-steal · HTTPS-страница для REALITY?' y) || return
        fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            if ! valid_domain "$NODE_DOMAIN"; then
                info '  Для сертификата нужен домен, указывающий на этот VPS.'
                NODE_DOMAIN=$(wizard_input 'Домен ноды' '' check_node_domain) || return
            fi
            SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER") || return
        fi
        if [[ $ENABLE_BBR == no ]]; then
            ENABLE_BBR=$(yes_no '  BBR + fq · оптимизация TCP?' y) || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == no ]]; then
            ENABLE_TRAFFIC_GUARD=$(yes_no '  TrafficGuard · блокировка известных сканеров?' n) || return
        fi

        ui_step 4 'Порты и защита' "$steps"
        if [[ $ENABLE_SECURITY == no && -z $VPN_PORTS ]]; then
            VPN_PORTS=443/tcp
            # shellcheck disable=SC2034 # A detected listener overrides this initial suggestion.
            VPN_PORTS_SAVED=no
        fi
        ENABLE_SECURITY=yes
        get_admin_ip || return
        detected_port=$(detect_ssh_port "$SSH_PORT") || return
        SSH_PORT=$(wizard_input 'Порт SSH' "${detected_port:-22}" check_ssh_port "$detected_port") || return
        ADMIN_IPS=${ADMIN_IPS:-$ADMIN_IP}
        if [[ $ENABLE_TRAFFIC_GUARD == yes && -z ${ADMIN_IP:-}${ADMIN_IPS:-} ]]; then
            ADMIN_IPS=$(wizard_input 'Доверенный IP для SSH' '' normalize_ips network) || return
            [[ -n $ADMIN_IPS ]] || { fail 'Для TrafficGuard нужен доверенный IP или подсеть.'; return 1; }
        fi
        PANEL_IPS=$(ask_panel_ips "$PANEL_IPS") || return
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  Укажите порт VLESS REALITY первым среди TCP-портов.'; fi
        VPN_PORTS=$(security_prompt_vpn_ports "$VPN_PORTS") || return
        security_preflight || return
        components+=', UFW, Fail2Ban'
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            wizard_selfsteal_preflight "$had_selfsteal" || result=$?
            if (( result == 2 )); then return 0; fi
            if (( result != 0 )); then return "$result"; fi
        fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            scope+=' selfsteal'
            components+=", $SELFSTEAL_SERVER"
            UI_INSTALL_PHASES+=("HTTPS и сертификат ($SELFSTEAL_SERVER)")
        fi
        if [[ $ENABLE_BBR == yes ]]; then
            scope+=' bbr'
            components+=', BBR + fq'
            UI_INSTALL_PHASES+=('Настройка BBR и fq')
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then
            components+=', TrafficGuard'
            UI_INSTALL_PHASES+=('TrafficGuard')
        fi
    fi

    node_preflight || return
    ui_step "$steps" 'Проверка настроек' "$steps"
    info "  Нода       $NODE_DOMAIN"
    info "  Node Port  $NODE_PORT/tcp"
    if [[ $mode == full ]]; then
        info "  IP панели  $PANEL_IPS"
        info "  SSH        $SSH_PORT/tcp"
        info "  VPN        ${VPN_PORTS:-будут настроены позже}"
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  ACME       80/tcp'; fi
    elif [[ $ENABLE_SECURITY == no || -z $PANEL_IPS ]]; then
        info "  В firewall разрешите $NODE_PORT/tcp только с IP панели."
    fi
    info "  Установка  $components"
    printf '\n'
    consent=$(yes_no '  Начать установку?' n) || return
    [[ $consent == yes ]] || { info 'Установка отменена.'; return 0; }
    if [[ $UI_CLEAR != yes ]]; then ui_screen "$UI_INSTALL_TITLE"; fi
    ui_install_phase node_prepare_image || return
    if [[ $mode == full ]]; then ui_install_phase prepare_security || return; fi
    run_change "$scope" apply_installation "$mode" || return
    printf '\n'
    ui_section 'Установка завершена'
    show_panel_help
}

apply_selfsteal() {
    save_config || return
    if [[ $1 == yes ]]; then ui_run 'Доступ для выпуска сертификата' security_allow_acme || return; fi
    ui_run "HTTPS и сертификат ($SELFSTEAL_SERVER)" selfsteal_apply || return
    show_panel_help
}

add_selfsteal() {
    local scope='config selfsteal' open_acme=no
    require_config || return
    if ! valid_domain "$NODE_DOMAIN"; then
        info '  Для сертификата нужен домен с DNS-записью на этот VPS.'
        NODE_DOMAIN=$(wizard_input 'Домен ноды' '' check_node_domain) || return
    fi
    ENABLE_SELFSTEAL=yes
    SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER" "${1-}") || return
    selfsteal_preflight || return
    if security_ufw_managed; then
        security_preflight || return
        open_acme=yes
        scope+=' network'
    else
        info '  Для сертификата пропустите TCP 80 в действующем firewall и у провайдера.'
    fi
    run_change "$scope" apply_selfsteal "$open_acme"
}

apply_security_settings() {
    save_config && ui_run 'UFW и Fail2Ban' security_apply || return
    if [[ $1 == yes ]]; then ui_run 'Обновление HTTPS-перенаправления' selfsteal_refresh_redirect || return; fi
}

configure_security() {
    local scope='config network' previous_port refresh=no consent
    require_config || return
    previous_port=$(selfsteal_public_port) || return
    if [[ ${UI_INTERACTIVE:-no} == yes || -z $PANEL_IPS ]]; then
        PANEL_IPS=$(ask_panel_ips "$PANEL_IPS") || return
    fi
    _standalone_access || return
    if [[ ${UI_INTERACTIVE:-no} == yes ]]; then
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  Укажите порт VLESS REALITY первым среди TCP-портов.'; fi
        VPN_PORTS=$(security_prompt_vpn_ports "$VPN_PORTS") || return
    fi
    ENABLE_SECURITY=yes
    security_preflight || return
    if [[ $ENABLE_SELFSTEAL == yes && $previous_port != "$(selfsteal_public_port)" ]] && selfsteal_verify; then
        scope+=' selfsteal'
        refresh=yes
    fi
    if [[ ${UI_INTERACTIVE:-no} == yes ]]; then
        info "  SSH $SSH_PORT/tcp · Панель $NODE_PORT/tcp (только $PANEL_IPS)"
        info "  Публичные порты · ${VPN_PORTS:-нет}"
        consent=$(yes_no '  Применить правила?' n) || return
        [[ $consent == yes ]] || return 0
    fi
    ui_run 'Пакеты защиты' prepare_security || return
    run_change "$scope" apply_security_settings "$refresh"
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
    if [[ $ENABLE_SECURITY == yes ]] && ! security_ufw_active; then
        fail 'Включите управляемый UFW через пункт «Порты и защита».'
        return 1
    fi
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
    if [[ $ENABLE_SECURITY == yes ]]; then security_status; fi
    if [[ -n $NODE_PORT || -n $VPN_PORTS ]]; then security_vpn_status || :; fi
    bbr_status
    traffic_guard_status
}

doctor() {
    local result=0 listeners=''
    if ! load_config && ! load_host_settings; then
        fail 'Сначала настройте ноду или один из компонентов.'
        return 1
    fi
    node_status || result=1
    if [[ $ENABLE_SELFSTEAL == yes ]]; then selfsteal_status || result=1; fi
    if [[ -n $NODE_PORT || -n $VPN_PORTS ]]; then
        if [[ $ENABLE_SECURITY == yes ]]; then
            security_vpn_status || result=1
        else
            listeners=$(security_detect_vpn_ports) || result=1
            info "Порты Xray · ${listeners:-пока не слушает}"
            if [[ -z $listeners ]]; then result=1; fi
        fi
    fi
    if [[ $ENABLE_SECURITY == yes ]]; then
        if ! security_ufw_active; then warn 'UFW неактивен.'; result=1; fi
        if ! fail2ban-client status sshd >/dev/null 2>&1; then warn 'Fail2Ban для SSH недоступен.'; result=1; fi
    fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status || result=1; fi
    security_os_updates_status
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
