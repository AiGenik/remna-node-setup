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
        ui_network_confirmation
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
    elif [[ -x /usr/sbin/sshd ]]; then
        (/usr/sbin/sshd -T 2>/dev/null || :) | awk '$1 == "port" && !seen++ { print $2 }'
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

ask_panel_ips() {
    info '  Узнайте IP на сервере панели.' >&2
    info '  curl -4fsS https://api.ipify.org' >&2
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
    info '  Ноды → Управление → выберите профиль.'
    info '  Сохраните ноду и проверьте подключение.'
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
    local mode=$1 image=$2 traffic_stage=$3
    save_config && save_secret || return
    if [[ $mode == full ]]; then
        ui_install_phase security_apply_current || return
    fi
    ui_install_phase node_apply "$image" || return
    if [[ $mode == full ]]; then
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            ui_install_phase selfsteal_apply || return
        fi
        if [[ $ENABLE_BBR == yes ]]; then
            ui_install_phase bbr_apply || return
        fi
        if [[ ${DISABLE_IPV6:-no} == yes ]]; then
            ui_install_phase ipv6_apply yes || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then
            ui_install_phase traffic_guard_apply "$traffic_stage" || return
        fi
    fi
    rm -f -- "$CONFIG_DIR/host.json" || return
    ui_install_progress "$UI_PROGRESS_DONE"
}

apply_selected_installation() (
    local scope=$1 mode=$2 image=$3 traffic_stage=''
    if [[ $mode == full && $ENABLE_TRAFFIC_GUARD == yes ]]; then
        traffic_stage=$(mktemp -d "$STATE_DIR/.traffic-guard.XXXXXX") || return
        trap 'rm -rf -- "$traffic_stage"' EXIT
        ui_install_phase traffic_guard_prepare "$traffic_stage" || return
    fi
    if [[ $mode == full && $ENABLE_SELFSTEAL == yes ]]; then
        release_wait_for_apt || return
    fi
    run_change "$scope" apply_installation "$mode" "$image" "$traffic_stage"
)

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
    local old_port='' had_selfsteal=no has_node=no has_host=no image vps_ips selfsteal_domain=''
    local gemini=no gemini_default=yes auto_updates=no auto_default=yes ipv6_default=yes
    local selfsteal_default=yes bbr_default=yes tg_default=yes
    local PSIPHON_REGION PSIPHON_PORT
    # shellcheck disable=SC2034 # The progress renderer reads the current wizard title.
    local UI_INSTALL_TITLE='Установка ноды'
    local UI_PROGRESS_DONE=0
    local -a UI_INSTALL_PHASES=('Docker и образ ноды')
    if [[ $mode == full ]]; then
        steps=6
        scope+=' network'
        UI_INSTALL_TITLE='Полная установка ноды (всё под ключ)'
    fi
    release_wait_for_apt || return
    ui_run 'Подготовка VPS' apt_install_missing ca-certificates curl python3 iproute2 || return

    if load_config; then
        has_node=yes
        old_port=$NODE_PORT
    elif [[ -e $CONFIG_DIR/node.json || -L $CONFIG_DIR/node.json ]]; then
        fail 'Не удалось прочитать настройки ноды. Проверьте node.json или восстановите снимок.'
        return 1
    else
        _standalone_load || return
        if [[ -e $CONFIG_DIR/host.json ]]; then has_host=yes; fi
    fi
    if [[ $has_node == no && $has_host == no ]]; then
        SELFSTEAL_SERVER=nginx
    fi
    had_selfsteal=$ENABLE_SELFSTEAL

    ui_step 1 'Служебный порт' "$steps"
    info '  В панели → Ноды → Управление → +'
    vps_ips=$(python3 "$PROJECT_DIR/lib/selfsteal-dns.py" --public-ips 2>/dev/null) || vps_ips=
    if [[ -n $vps_ips ]]; then info "  IP VPS для карточки ноды · $vps_ips"; fi
    info '  Скопируйте Node Port из Compose.'
    NODE_PORT=$(wizard_input 'NODE_PORT из панели' "${old_port:-2222}" check_node_port) || return
    if [[ $mode == node-only && $ENABLE_SECURITY == yes && $has_node == yes && $NODE_PORT != "$old_port" ]]; then
        fail 'Чтобы сменить служебный порт в управляемом UFW, перенастройте ноду через полное меню.'
        return 1
    fi

    ui_step 2 'Ключ подключения' "$steps"
    info '  Вставьте Secret Key из карточки ноды.'
    ask_secret || return

    if [[ $mode == full ]]; then
        ui_step 3 'Профиль «Всё под ключ»' "$steps"
        if [[ $has_node == yes || $has_host == yes ]]; then
            selfsteal_default=$ENABLE_SELFSTEAL
            bbr_default=$ENABLE_BBR
            tg_default=$ENABLE_TRAFFIC_GUARD
            ipv6_default=${DISABLE_IPV6:-yes}
            if ! psiphon_is_managed; then gemini_default=n; fi
            if declare -F auto_update_enabled >/dev/null && ! auto_update_enabled; then auto_default=n; fi
        fi
        ENABLE_SELFSTEAL=$(yes_no '  Self-steal для REALITY (Nginx + Certbot)?' "$([[ $selfsteal_default == yes ]] && printf y || printf n)") || return
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            if valid_domain "$NODE_DOMAIN"; then selfsteal_domain=$NODE_DOMAIN; fi
            info '  Для HTTPS укажите домен, направленный на этот VPS.'
            NODE_DOMAIN=$(wizard_input 'Домен self-steal' "$selfsteal_domain" check_node_domain) || return
            SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER") || return
        fi
        ENABLE_BBR=$(yes_no '  Включить BBR и fq?' "$([[ $bbr_default == yes ]] && printf y || printf n)") || return
        DISABLE_IPV6=$(yes_no '  Отключить IPv6 на сервере?' "$([[ $ipv6_default == yes ]] && printf y || printf n)") || return
        ENABLE_TRAFFIC_GUARD=$(yes_no '  Включить TrafficGuard (против сканеров)?' "$([[ $tg_default == yes ]] && printf y || printf n)") || return
        gemini=$(yes_no '  Настроить Gemini через Psiphon?' "$([[ $gemini_default == yes ]] && printf y || printf n)") || return
        if [[ $gemini == yes ]]; then psiphon_select_settings || return; fi
        auto_updates=$(yes_no '  Включить ночные автообновления (04:00)?' "$([[ $auto_default == yes ]] && printf y || printf n)") || return

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
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  Первый TCP-порт — для REALITY.'; fi
        VPN_PORTS=$(security_prompt_vpn_ports "$VPN_PORTS") || return
        security_preflight || return
        components+=', UFW, Fail2Ban'
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            wizard_selfsteal_preflight "$had_selfsteal" || result=$?
            if (( result == 2 )); then return 0; fi
            if (( result != 0 )); then return "$result"; fi
        fi
        UI_INSTALL_PHASES+=('Пакеты защиты')
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then UI_INSTALL_PHASES+=('Проверка версии и базы TrafficGuard'); fi
        UI_INSTALL_PHASES+=('UFW и Fail2Ban' 'Контейнер Remnawave')
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
        if [[ $DISABLE_IPV6 == yes ]]; then
            scope+=' ipv6'
            components+=', IPv6 выкл'
            UI_INSTALL_PHASES+=('Отключение IPv6')
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then
            components+=', TrafficGuard'
            UI_INSTALL_PHASES+=('Применение базы TrafficGuard')
        fi
        if [[ $gemini == yes ]]; then
            components+=', Psiphon (Gemini)'
            UI_INSTALL_PHASES+=('Gemini через Psiphon')
        fi
        if [[ $auto_updates == yes ]]; then
            components+=', автообновления'
            UI_INSTALL_PHASES+=('Ночные автообновления')
        fi
    else
        UI_INSTALL_PHASES+=('Контейнер Remnawave')
    fi

    node_preflight || return
    if [[ $mode == full ]]; then
        ui_step 5 'Проверка соединения' "$steps"
        if ! port_preflight install "$NODE_PORT" "$VPN_PORTS" "$PANEL_IPS" "$NODE_DOMAIN"; then
            if [[ $UI_INTERACTIVE != yes ]]; then return 1; fi
            consent=$(yes_no '  Продолжить установку?' n) || return
            if [[ $consent != yes ]]; then info 'Установка отменена.'; return 0; fi
        fi
    fi
    ui_step "$steps" 'Проверка настроек' "$steps"
    if [[ -n $NODE_DOMAIN ]]; then info "  Адрес      $NODE_DOMAIN"; fi
    info "  Node Port  $NODE_PORT/tcp"
    if [[ $mode == full ]]; then
        info "  IP панели  $PANEL_IPS"
        info "  SSH        $SSH_PORT/tcp"
        info "  VPN        ${VPN_PORTS:-будут настроены позже}"
        info "  IPv6       $([[ $DISABLE_IPV6 == yes ]] && printf 'отключён' || printf 'включён')"
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  ACME       80/tcp (webroot)'; fi
        if [[ $gemini == yes ]]; then
            info "  Gemini     Psiphon (${PSIPHON_REGION:-auto}) · 127.0.0.1:$PSIPHON_PORT"
        fi
    elif [[ $ENABLE_SECURITY == no || -z $PANEL_IPS ]]; then
        info "  В firewall разрешите $NODE_PORT/tcp только с IP панели."
    fi
    info "  Установка  $components"
    printf '\n'
    consent=$(yes_no '  Начать установку?' y) || return
    [[ $consent == yes ]] || { info 'Установка отменена.'; return 0; }
    if [[ $UI_CLEAR == yes ]]; then ui_install_progress "$UI_PROGRESS_DONE"; else ui_screen "$UI_INSTALL_TITLE"; fi
    image=$(node_release_image) || return
    ui_install_phase node_prepare_image "$image" || return
    if [[ $mode == full ]]; then ui_install_phase prepare_security || return; fi
    apply_selected_installation "$scope" "$mode" "$image" || return
    if [[ $gemini == yes || $auto_updates == yes ]]; then
        local tail_phases=0
        if [[ $gemini == yes ]]; then tail_phases=$((tail_phases + 1)); fi
        if [[ $auto_updates == yes ]]; then tail_phases=$((tail_phases + 1)); fi
        # apply_selected_installation updates UI_PROGRESS_DONE inside a subshell.
        UI_PROGRESS_DONE=$((${#UI_INSTALL_PHASES[@]} - tail_phases))
    fi
    if [[ $gemini == yes ]]; then
        if ! ui_install_phase psiphon_apply_settings "$PSIPHON_REGION" "$PSIPHON_PORT"; then
            warn 'Нода настроена. Повторите настройку Gemini в [2] → [8] после подтверждения SSH.'
            if [[ $UI_CLEAR == yes ]]; then ui_network_confirmation; fi
            return 1
        fi
        ui_install_progress "$UI_PROGRESS_DONE"
    fi
    if [[ $auto_updates == yes ]] && declare -F auto_update_configure >/dev/null; then
        ui_install_phase auto_update_configure enable || warn 'Не удалось включить автообновления; повторите в [5] → [9].'
        ui_install_progress "$UI_PROGRESS_DONE"
    fi
    printf '\n'
    ui_section 'Установка завершена'
    if [[ $mode == full && $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status; fi
    show_panel_help
    if [[ $gemini == yes ]]; then
        printf '\n'
        ui_section 'Gemini через Psiphon'
        info '  Откройте [2] → [9] и добавьте шаблон в профиль ноды в Remnawave.'
        if [[ $UI_CLEAR == yes ]]; then
            printf '\n'
            ui_network_confirmation
        fi
    fi
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
    release_wait_for_apt || return
    run_change "$scope" apply_selfsteal "$open_acme"
}

apply_security_settings() {
    save_config && ui_run 'Пакеты и правила UFW / Fail2Ban' security_apply_current || return
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
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  Первый TCP-порт — для REALITY.'; fi
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

apply_ipv6() {
    DISABLE_IPV6=$1
    save_config && ipv6_apply "$DISABLE_IPV6"
}

configure_ipv6() {
    local action=${1-} desired scope='config ipv6' answer
    require_config || return
    case "$action" in
        status) ipv6_status; return ;;
        disable) desired=yes ;;
        enable) desired=no ;;
        '')
            ipv6_status
            if [[ $UI_INTERACTIVE != yes ]]; then return 0; fi
            if [[ ${DISABLE_IPV6:-no} == yes ]] ||
                [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(< /proc/sys/net/ipv6/conf/all/disable_ipv6) != 0 ]]; then
                answer=$(yes_no '  Включить IPv6 обратно?' n) || return
                [[ $answer == yes ]] || return 0
                desired=no
            else
                answer=$(yes_no '  Отключить IPv6 на сервере?' y) || return
                [[ $answer == yes ]] || return 0
                desired=yes
            fi
            ;;
        *) fail 'Используйте: remna-node-setup ipv6 [disable|enable|status].'; return 1 ;;
    esac
    if declare -F _selfsteal_nginx_owned_config >/dev/null && _selfsteal_nginx_owned_config; then
        scope+=' selfsteal'
    fi
    run_change "$scope" apply_ipv6 "$desired"
}

repair_security_boot() {
    local consent
    security_ufw_active || { fail 'Сначала включите UFW в [2] → [3] «Порты, UFW и защита SSH».'; return 1; }
    if [[ ${UI_INTERACTIVE:-no} == yes ]]; then
        consent=$(yes_no '  Восстановить автозапуск защитных служб?' n) || return
        [[ $consent == yes ]] || return 0
    fi
    run_change network security_repair_boot
}

apply_traffic_guard() {
    save_config && ui_run 'Применение базы TrafficGuard' traffic_guard_apply "$1"
}

prepare_and_change_traffic_guard() (
    local callback=$1 stage
    stage=$(mktemp -d "$STATE_DIR/.traffic-guard.XXXXXX") || return
    trap 'rm -rf -- "$stage"' EXIT
    ui_run 'Проверка версии и базы TrafficGuard' traffic_guard_prepare "$stage" || return
    run_change 'config network' "$callback" "$stage" || return
    traffic_guard_status
)

configure_traffic_guard() {
    local consent
    require_config || return
    [[ -n ${ADMIN_IP:-}${ADMIN_IPS:-} ]] || { fail 'Укажите доверенный адрес при запуске мастера.'; return 1; }
    security_ufw_active || { fail 'Сначала включите UFW через [2] → [3] «Порты, UFW и защита SSH».'; return 1; }
    if [[ ! -f $STATE_DIR/traffic-guard/version ]] &&
       declare -F _traffic_guard_external_present >/dev/null && _traffic_guard_external_present; then
        fail 'Обнаружен ранее настроенный TrafficGuard или общий /etc/ipset.conf.'
        return 1
    fi
    consent=$(yes_no 'Проверить и применить свежую версию и базу TrafficGuard?' n) || return
    [[ $consent == yes ]] || return 0
    ENABLE_TRAFFIC_GUARD=yes
    prepare_and_change_traffic_guard apply_traffic_guard
}

apply_system_package_updates() {
    local plan=$1 ufw_active=no guard_active=no restart_nginx=no restart_caddy=no
    local service sshd_jail_active=no
    local -a check_services=()
    if security_ufw_active; then ufw_active=yes; fi
    if [[ -s $STATE_DIR/traffic-guard/version ]] && traffic_guard_firewall_active; then guard_active=yes; fi
    if grep -Eq '^(nginx|nginx-[a-z]+|libnginx-mod-[a-z0-9-]+)[[:space:]]' <<< "$plan" &&
        systemctl is-active --quiet nginx.service; then
        nginx -t || return
        restart_nginx=yes
    fi
    if grep -q $'^caddy\t' <<< "$plan" && systemctl is-active --quiet caddy.service; then restart_caddy=yes; fi
    if grep -q $'^fail2ban\t' <<< "$plan" && systemctl is-active --quiet fail2ban.service; then
        check_services+=(fail2ban.service)
        if fail2ban-client status sshd >/dev/null 2>&1; then sshd_jail_active=yes; fi
    fi
    if grep -Eq '^(docker-ce|docker.io|containerd.io|containerd)[[:space:]]' <<< "$plan" &&
        systemctl is-active --quiet docker.service; then
        check_services+=(docker.service)
    fi

    apt_upgrade_installed_apply "$plan" || return
    if [[ $ufw_active == yes ]] && ! security_ufw_active; then
        fail 'После обновления UFW неактивен.'
        return 1
    fi
    security_restore_traffic_guard "$guard_active" || return
    if [[ $restart_nginx == yes ]]; then
        nginx -t && systemctl restart nginx.service && systemctl is-active --quiet nginx.service || return
    fi
    if [[ $restart_caddy == yes ]]; then
        systemctl restart caddy.service && systemctl is-active --quiet caddy.service || return
    fi
    for service in "${check_services[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
            fail "После обновления служба $service не запущена."
            return 1
        fi
    done
    if [[ $sshd_jail_active == yes ]] && ! fail2ban-client status sshd >/dev/null 2>&1; then
        fail 'После обновления Fail2Ban не защищает SSH.'
        return 1
    fi
}

system_package_update_plan() {
    local selected=${1-}
    local -a packages=(nginx nginx-common nginx-core nginx-full nginx-light nginx-extras libnginx-mod-stream
        caddy certbot python3-certbot python3-acme ufw fail2ban python3-systemd ipset iptables
        docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io docker.io docker-compose-v2 containerd)
    if [[ -n $selected ]]; then
        if [[ " ${packages[*]} " != *" $selected "* ]]; then
            fail "Пакет $selected не входит в список поддерживаемых компонентов."
            return 1
        fi
        packages=("$selected")
    fi
    apt_upgrade_installed_preview "${packages[@]}"
}

update_system_packages() {
    local plan effects consent ufw_state=inactive
    plan=$(system_package_update_plan "$1") || return
    if [[ -z $plan ]]; then
        info 'Нет доступных обновлений выбранных установленных пакетов.'
        return 0
    fi
    awk -F '\t' '{printf "  %-23s %s → %s\n", $1, $2, $3}' <<< "$plan"
    effects=$(apt_upgrade_installed_effects "$plan") || return
    [[ -n $effects ]] || return 0
    ui_attention 'Обновление может перезапустить службы и прервать подключения.'
    if [[ $UI_INTERACTIVE == yes ]]; then
        consent=$(yes_no '  Установить эти обновления?' n) || return
        [[ $consent == yes ]] || return 0
    fi
    if update_effects_touch_network "$effects" && command -v ufw >/dev/null; then
        ufw_state=$(security_ufw_state) || { fail 'Не удалось проверить состояние UFW.'; return 1; }
    fi
    if [[ $ufw_state == active ]]; then
        run_change network ui_run 'Обновление установленных пакетов' apply_system_package_updates "$plan" || return
    else
        ui_run 'Обновление установленных пакетов' apply_system_package_updates "$plan" || return
    fi
    info 'Обновление пакетов завершено.'
}

update_node() {
    local image installed
    if [[ ! -e $CONFIG_DIR/node.json ]] &&
       declare -F _node_external_inspect >/dev/null && ! _node_owned_config && _node_external_inspect; then
        local loc=${_NODE_EXT_DIR:-/opt/remnanode}
        info "Найдена внешняя нода ($loc)."
        info "Чтобы не затронуть её конфигурацию, обновляйте контейнер её compose-файлом (cd $loc && docker compose pull && docker compose up -d)."
        return 0
    fi
    require_config || return
    if [[ $ENABLE_SECURITY == yes ]] && ! security_ufw_active; then
        fail 'Включите управляемый UFW через [2] → [3] «Порты, UFW и защита SSH».'
        return 1
    fi
    node_preflight || return
    image=$(node_release_image) || return
    if [[ ${1-} == if-needed ]]; then
        installed=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return
        if [[ $image == "$installed" ]] && node_verify; then
            info 'Нода актуальна.'
            return 0
        fi
    fi
    node_prepare_image "$image" || return
    run_change node node_apply "$image"
}

_legacy_host_detected() {
    { declare -F _node_external_inspect >/dev/null && ! _node_owned_config && _node_external_inspect; } && return 0
    { declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; } && return 0
    { declare -F security_ufw_active >/dev/null && security_ufw_active 2>/dev/null; } && return 0
    { declare -F _psiphon_existing_install >/dev/null && _psiphon_existing_install 2>/dev/null; } && return 0
    { declare -F _traffic_guard_external_present >/dev/null && _traffic_guard_external_present 2>/dev/null; } && return 0
    return 1
}

backup_scope() {
    local scope='config'
    if [[ -n $NODE_PORT ]]; then scope+=' node'; fi
    if [[ $ENABLE_SECURITY == yes || $ENABLE_TRAFFIC_GUARD == yes ]]; then scope+=' network'; fi
    if [[ $ENABLE_SELFSTEAL == yes ]]; then scope+=' selfsteal'; fi
    if [[ $ENABLE_BBR == yes ]]; then scope+=' bbr'; fi
    if [[ ${DISABLE_IPV6:-no} == yes ]]; then scope+=' ipv6'; fi
    printf '%s\n' "$scope"
}

create_backup() {
    local id scope
    if ! load_config && ! load_host_settings; then
        if _legacy_host_detected; then
            local dir
            local -a legacy_paths=(
                /opt/remnanode /etc/nginx /etc/caddy /etc/letsencrypt/renewal
                /etc/ufw /etc/default/ufw /etc/fail2ban /etc/ipset.conf /etc/sysctl.d
                /etc/default/vps-psiphon
            )
            if [[ -n ${LEGACY_SNAPSHOT_PATHS:-} ]]; then
                read -r -a legacy_paths <<< "$LEGACY_SNAPSHOT_PATHS"
            fi
            dir=$(mktemp -d "$BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || return
            chmod 0700 "$dir" || return
            mkdir -- "$dir/files" || return
            path_snapshot "$dir" "${legacy_paths[@]}" || return
            printf 'external\n' > "$dir/scopes" || return
            info "Архивная копия конфигов существующего сервера сохранена в $dir."
            return 0
        fi
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
    if [[ $scope == external ]]; then
        fail "Это архивная копия внешней установки ($BACKUP_DIR/$id/files); автоматический откат для неё отключён во избежание конфликта."
        return 1
    fi
    run_change "$scope" restore_snapshot "$id" "$scope"
}

status_all() {
    local id
    id=$(pending_id) || return
    if [[ -n $id ]]; then ui_network_confirmation; fi
    if ! load_config && ! load_host_settings; then
        node_status || :
        if _legacy_host_detected; then
            if { declare -F _selfsteal_caddy_owned_config >/dev/null && _selfsteal_caddy_owned_config; } ||
               { declare -F _selfsteal_nginx_owned_config >/dev/null && _selfsteal_nginx_owned_config; } ||
               { declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; }; then
                selfsteal_status || :
            fi
            if declare -F security_status >/dev/null; then security_status; fi
            if { declare -F _node_external_inspect >/dev/null && _node_external_inspect; } ||
               [[ -n $(security_detect_vpn_ports 2>/dev/null || :) ]]; then
                security_vpn_status || :
            fi
            bbr_status
            ipv6_status
            traffic_guard_status || :
            psiphon_status || :
            if declare -F auto_update_status >/dev/null; then auto_update_status || :; fi
            return 0
        fi
        if psiphon_is_managed; then
            psiphon_status || :
        else
            info 'Начните с мастера или выберите отдельный компонент.'
        fi
        return 0
    fi
    node_status || :
    if [[ $ENABLE_SELFSTEAL == yes ]] ||
       { declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; }; then
        selfsteal_status || :
    fi
    if [[ $ENABLE_SECURITY == yes ]] ||
       { declare -F security_ufw_active >/dev/null && security_ufw_active 2>/dev/null; }; then
        security_status
    fi
    if [[ -n $NODE_PORT || -n $VPN_PORTS ]] ||
       { declare -F _node_external_inspect >/dev/null && ! _node_owned_config && _node_external_inspect; }; then
        security_vpn_status || :
    fi
    bbr_status
    ipv6_status
    traffic_guard_status || :
    psiphon_status || :
    if declare -F auto_update_status >/dev/null; then auto_update_status || :; fi
}

_doctor_host_footer() {
    local result=0
    security_os_updates_status
    bbr_status
    ipv6_status
    if command -v timedatectl >/dev/null 2>&1; then
        if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || :) == yes ]]; then
            info 'Время синхронизировано по NTP.'
        else
            warn 'Синхронизация времени NTP не подтверждена (критично для REALITY). Проверьте systemd-timesyncd (time.cloudflare.com) и UDP/123.'
        fi
    fi
    df -h -- "$STATE_DIR" "$BACKUP_DIR" || result=1
    return "$result"
}

doctor() {
    local result=0 listeners=''
    if ! load_config && ! load_host_settings; then
        if _legacy_host_detected; then
            if declare -F _node_external_inspect >/dev/null && _node_external_inspect; then
                node_status required || result=1
                if valid_port "${_NODE_EXT_PORT:-}" && security_ufw_active 2>/dev/null; then
                    local ext_panel=''
                    ext_panel=$(security_ufw_panel_ips_for_port "$_NODE_EXT_PORT" 2>/dev/null || :)
                    if [[ -n $ext_panel ]]; then
                        info "UFW: порт ноды $_NODE_EXT_PORT/tcp разрешён для панели ($ext_panel)."
                    elif LC_ALL=C ufw status 2>/dev/null | grep -Eq "^$_NODE_EXT_PORT(/tcp)?[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere"; then
                        warn "UFW: порт ноды $_NODE_EXT_PORT/tcp открыт для Anywhere; рекомендуется ограничить только IP панели."
                        result=1
                    else
                        warn "UFW: не найдено явное правило разрешения $_NODE_EXT_PORT/tcp для панели."
                        result=1
                    fi
                fi
            fi
            if { declare -F _selfsteal_caddy_owned_config >/dev/null && _selfsteal_caddy_owned_config; } ||
               { declare -F _selfsteal_nginx_owned_config >/dev/null && _selfsteal_nginx_owned_config; } ||
               { declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; }; then
                selfsteal_status || result=1
                if [[ -n ${_SELFSTEAL_EXT_DOMAIN:-} ]]; then
                    NODE_DOMAIN=$_SELFSTEAL_EXT_DOMAIN _selfsteal_validate_domain report || result=1
                fi
            fi
            if declare -F security_vpn_status >/dev/null; then
                security_vpn_status || result=1
            fi
            if security_ufw_active 2>/dev/null; then
                if ! security_ufw_has_deny_incoming 2>/dev/null; then
                    warn 'UFW: политика по умолчанию отличается от deny (incoming).'
                    result=1
                fi
                if ! security_ufw_boot_verified; then result=1; fi
            else
                warn 'UFW неактивен.'
                result=1
            fi
            if ! fail2ban-client status sshd >/dev/null 2>&1; then
                warn 'Fail2Ban для SSH недоступен.'
                result=1
            fi
            if { declare -F _traffic_guard_external_present >/dev/null && _traffic_guard_external_present; } ||
               [[ -s $STATE_DIR/traffic-guard/version ]]; then
                traffic_guard_status || result=1
            fi
            if psiphon_is_managed || { declare -F _psiphon_existing_install >/dev/null && _psiphon_existing_install; }; then
                psiphon_status || result=1
            fi
            _doctor_host_footer || result=1
            return "$result"
        fi
        if psiphon_is_managed; then psiphon_status; return; fi
        fail 'Сначала настройте ноду или один из компонентов.'
        return 1
    fi
    if [[ -n $NODE_PORT ]]; then node_status required || result=1; fi
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_status || result=1
        _selfsteal_validate_domain report || result=1
    elif declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; then
        selfsteal_status || result=1
        NODE_DOMAIN=$_SELFSTEAL_EXT_DOMAIN _selfsteal_validate_domain report || result=1
    fi
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
        if ! security_ufw_boot_verified; then result=1; fi
        if ! fail2ban-client status sshd >/dev/null 2>&1; then warn 'Fail2Ban для SSH недоступен.'; result=1; fi
    fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status required || result=1; fi
    if psiphon_is_managed || { declare -F _psiphon_existing_install >/dev/null && _psiphon_existing_install; }; then
        psiphon_status || result=1
    fi
    _doctor_host_footer || result=1
    return "$result"
}

audit_live() {
    local result=0 port=1080 ban_action='' gemini_code gemini_ip yt_code cert_dir
    ui_section 'Базовая проверка ноды и сервисов'
    doctor || result=1
    printf '\n'
    ui_section 'Живой аудит сети, маршрутов и сертификата'

    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
        if declare -F security_fail2ban_action >/dev/null; then
            ban_action=$(security_fail2ban_action 2>/dev/null || :)
        fi
        info "Fail2Ban sshd · активен (${ban_action:-настроен})."
    fi

    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(< /proc/sys/net/ipv6/conf/all/disable_ipv6) == 1 ]]; then
        info 'IPv6 · отключён (трафик идёт стабильно по IPv4).'
    else
        warn 'IPv6 · не отключён (при желании отключите в [2] → [6]).'
    fi

    if command -v certbot >/dev/null 2>&1; then
        cert_dir="$STATE_DIR/nginx-certbot"
        if [[ ${ENABLE_SELFSTEAL:-no} == yes && ${SELFSTEAL_SERVER:-} == nginx ]] &&
           [[ -d $cert_dir/config/renewal ]]; then
            info 'Проверяю тестовое продление сертификата (Certbot dry-run)…'
            if certbot --config-dir "$cert_dir/config" --work-dir "$cert_dir/work" --logs-dir "$cert_dir/logs" \
                renew --dry-run --no-random-sleep-on-renew >/dev/null 2>&1; then
                info 'Certbot dry-run · автопродление сертификата проходит без конфликта с Nginx.'
            else
                warn 'Certbot dry-run · ошибка тестового продления (проверьте 80/tcp и DNS).'
                result=1
            fi
        elif [[ -d /etc/letsencrypt/renewal ]] &&
             find /etc/letsencrypt/renewal -maxdepth 1 -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
            info 'Проверяю тестовое продление системного сертификата (Certbot dry-run)…'
            if certbot renew --dry-run --no-random-sleep-on-renew >/dev/null 2>&1; then
                info 'Certbot dry-run · автопродление сертификата (/etc/letsencrypt) проходит без ошибок.'
            else
                warn 'Certbot dry-run · ошибка тестового продления (/etc/letsencrypt, проверьте 80/tcp и DNS).'
                result=1
            fi
        fi
    fi

    if declare -F psiphon_active_port >/dev/null; then
        port=$(psiphon_active_port 2>/dev/null || printf '1080')
    fi
    if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q "127.0.0.1:$port"; then
        local gemini_check=${PSIPHON_GEMINI_CHECK_BIN:-/usr/local/sbin/vps-psiphon-gemini-check} gem_out='' gem_rc=0
        info "Проверяю выход Gemini через Psiphon (127.0.0.1:$port)…"
        gemini_ip=$(curl --socks5-hostname "127.0.0.1:$port" -sS --connect-timeout 6 --max-time 10 \
            'https://api.ipify.org' 2>/dev/null || :)
        if [[ -x $gemini_check ]]; then
            gem_out=$("$gemini_check" 2>&1) || gem_rc=$?
            case "$gem_rc" in
                0) info "Psiphon (127.0.0.1:$port${gemini_ip:+, IP $gemini_ip}) → Gemini: сообщение отправлено и ответ получен (${gem_out#ok — })." ;;
                1) warn "Psiphon (127.0.0.1:$port${gemini_ip:+, IP $gemini_ip}) → Gemini ОТКЛОНИЛ сообщение: $gem_out"; result=1 ;;
                3) warn "Psiphon (127.0.0.1:$port${gemini_ip:+, IP $gemini_ip}) → Gemini требует КАПЧУ (/sorry): $gem_out"; result=1 ;;
                *)
                    if grep -qiE '/sorry|captcha' <<< "$gem_out"; then
                        warn "Psiphon (127.0.0.1:$port${gemini_ip:+, IP $gemini_ip}) → Gemini отправил на КАПЧУ: $gem_out"
                        result=1
                    else
                        gemini_code=$(curl --socks5-hostname "127.0.0.1:$port" -sS -o /dev/null -w '%{http_code}' \
                            --connect-timeout 6 --max-time 12 'https://gemini.google.com/app' 2>/dev/null || printf '000')
                        if [[ $gemini_code =~ ^(200|301|302)$ ]]; then
                            warn "Psiphon (127.0.0.1:$port${gemini_ip:+, IP $gemini_ip}) → Сайт открывается (HTTP $gemini_code), но тестовое сообщение не подтвердилось: $gem_out"
                            result=1
                        else
                            warn "Psiphon (127.0.0.1:$port) → Gemini ответил HTTP $gemini_code ($gem_out)."
                            result=1
                        fi
                    fi
                    ;;
            esac
        else
            gemini_code=$(curl --socks5-hostname "127.0.0.1:$port" -sS -o /dev/null -w '%{http_code}' \
                --connect-timeout 6 --max-time 12 'https://gemini.google.com/app' 2>/dev/null || printf '000')
            if [[ $gemini_code =~ ^(200|301|302)$ ]]; then
                info "Psiphon (127.0.0.1:$port) → Gemini HTTP $gemini_code${gemini_ip:+ · egress IP $gemini_ip}."
            else
                warn "Psiphon (127.0.0.1:$port) → Gemini ответил HTTP $gemini_code."
                result=1
            fi
        fi
    else
        info "Psiphon · не запущен на 127.0.0.1:$port (пропуск теста Gemini)."
    fi

    if command -v curl >/dev/null 2>&1; then
        yt_code=$(curl -4 -sS -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 10 \
            'https://www.youtube.com/' 2>/dev/null || printf '000')
        if [[ $yt_code =~ ^(200|301|302)$ ]]; then
            info "YouTube прямой выход (IPv4) → HTTP $yt_code."
        else
            warn "YouTube прямой выход (IPv4) → HTTP $yt_code."
            result=1
        fi
    fi
    return "$result"
}

check_dns() {
    local domain=${1-}
    if [[ -z $domain ]]; then
        if load_config || load_host_settings; then
            domain=$NODE_DOMAIN
        elif declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; then
            domain=$_SELFSTEAL_EXT_DOMAIN
        fi
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
        audit) [[ $# == 1 ]] || return 2; audit_live; return ;;
        versions) [[ $# == 1 ]] || return 2; show_versions; return ;;
        dns) [[ $# -le 2 ]] || return 2; check_dns "$target"; return ;;
        logs) [[ $# == 1 ]] || return 2; node_logs; return ;;
        vpn-port)
            if [[ $target == profile ]]; then
                [[ $# == 4 ]] || return 2
                vpn_port_profile "$3" "$4"
                return
            fi
            ;;
        auto-updates)
            if [[ $# == 2 && $target == status ]]; then auto_update_status; return; fi
            ;;
        psiphon)
            case "$target" in
                status) [[ $# == 2 ]] || return 2; psiphon_status; return ;;
                profile) [[ $# -le 3 ]] || return 2; psiphon_profile "${3-}"; return ;;
                profile-merge) [[ $# -le 3 ]] || return 2; psiphon_profile_merge "${3-}"; return ;;
            esac
            ;;
    esac
    release_acquire_lock || return
    case "$action" in
        confirm) [[ $# == 1 ]] || return 2; confirm_network; return ;;
        __ssh-confirm) [[ $# == 2 ]] && valid_ssh_ticket "$target" || return 2; confirm_network "$target"; return ;;
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
            if [[ $# == 2 && $target == boot ]]; then repair_security_boot; return; fi
            [[ $# == 1 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then configure_security; else standalone_security; fi
            ;;
        vpn-port)
            case $target in
                '') [[ $# == 1 && ${UI_INTERACTIVE:-no} == yes ]] || return 2; vpn_port_wizard ;;
                prepare) [[ $# == 4 ]] || return 2; vpn_port_prepare "$3" "$4" ;;
                finish) [[ $# == 3 && $3 =~ ^(keep|close)$ ]] || return 2; vpn_port_finish "$3" ;;
                cancel) [[ $# == 2 ]] || return 2; vpn_port_cancel ;;
                close) [[ $# == 3 ]] || return 2; vpn_port_close "$3" ;;
                *) return 2 ;;
            esac
            ;;
        bbr)
            [[ $# == 1 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then configure_bbr; else standalone_bbr; fi
            ;;
        ipv6)
            [[ $# -le 2 ]] || return 2
            if [[ -e $CONFIG_DIR/node.json ]]; then configure_ipv6 "$target"; else standalone_ipv6 "$target"; fi
            ;;
        preflight) [[ $# == 1 ]] || return 2; standalone_port_preflight ;;
        backup) [[ $# == 1 ]] || return 2; create_backup ;;
        restore) [[ $# == 2 ]] || return 2; do_restore "$target" ;;
        auto-updates) [[ $# -le 2 ]] || return 2; auto_update_configure "$target" ;;
        psiphon) [[ $# == 1 ]] || return 2; psiphon_configure ;;
        rollback) release_rollback ;;
        update)
            case "$target" in
                tool) [[ $# -le 3 ]] || return 2; release_update "${3-}" ;;
                node) [[ $# == 2 ]] || return 2; update_node force ;;
                all) [[ $# == 2 ]] || return 2; update_all manual ;;
                psiphon) [[ $# == 2 ]] || return 2; psiphon_update_action ;;
                packages) [[ $# -le 3 ]] || return 2; update_system_packages "${3-}" ;;
                traffic-guard)
                    [[ $# == 2 ]] || return 2
                    if [[ -e $CONFIG_DIR/node.json ]]; then configure_traffic_guard; else standalone_traffic_guard; fi
                    ;;
                *) usage >&2; return 2 ;;
            esac ;;
        *) usage >&2; return 2 ;;
    esac
)
