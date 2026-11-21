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
    local old_address='' old_port='' had_selfsteal=no has_node=no image
    local gemini=no gemini_default=n PSIPHON_REGION PSIPHON_PORT
    # shellcheck disable=SC2034 # The progress renderer reads the current wizard title.
    local UI_INSTALL_TITLE='Установка ноды'
    local UI_PROGRESS_DONE=0
    local -a UI_INSTALL_PHASES=('Docker и образ ноды')
    if [[ $mode == full ]]; then
        steps=5
        scope+=' network'
        UI_INSTALL_TITLE='Установка ноды и компонентов'
    fi
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
    info '  В панели → Ноды → Управление → +'
    info '  Введите тот же адрес, что и в панели.'
    NODE_DOMAIN=$(wizard_input 'Адрес ноды' "$old_address" check_node_address) || return
    if [[ $mode == node-only && $had_selfsteal == yes && $NODE_DOMAIN != "$old_address" ]]; then
        fail "Для HTTPS используется $old_address. Чтобы сменить адрес, откройте «Нода и компоненты»."
        return 1
    fi
    info '  Скопируйте Node Port из Compose.'
    NODE_PORT=$(wizard_input 'NODE_PORT из панели' "${old_port:-2222}" check_node_port) || return
    if [[ $mode == node-only && $ENABLE_SECURITY == yes && $has_node == yes && $NODE_PORT != "$old_port" ]]; then
        fail 'Чтобы сменить служебный порт в управляемом UFW, откройте «Нода и компоненты».'
        return 1
    fi

    ui_step 2 'Ключ подключения' "$steps"
    info '  Вставьте Secret Key из карточки ноды.'
    ask_secret || return

    if [[ $mode == full ]]; then
        ui_step 3 'Дополнительные компоненты' "$steps"
        if [[ $ENABLE_SELFSTEAL == no ]]; then
            ENABLE_SELFSTEAL=$(yes_no '  Self-steal для REALITY?' y) || return
        fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then
            if ! valid_domain "$NODE_DOMAIN"; then
                info '  Для сертификата нужен домен, указывающий на этот VPS.'
                NODE_DOMAIN=$(wizard_input 'Домен ноды' '' check_node_domain) || return
            fi
            SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER") || return
        fi
        if [[ $ENABLE_BBR == no ]]; then
            ENABLE_BBR=$(yes_no '  Включить BBR?' y) || return
        fi
        if [[ $ENABLE_TRAFFIC_GUARD == no ]]; then
            ENABLE_TRAFFIC_GUARD=$(yes_no '  Включить TrafficGuard?' n) || return
        fi
        if psiphon_is_managed; then gemini_default=y; fi
        gemini=$(yes_no '  Настроить Gemini через Psiphon?' "$gemini_default") || return
        if [[ $gemini == yes ]]; then psiphon_select_settings || return; fi

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
        if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then
            components+=', TrafficGuard'
            UI_INSTALL_PHASES+=('Применение базы TrafficGuard')
        fi
        if [[ $gemini == yes ]]; then UI_INSTALL_PHASES+=('Gemini через Psiphon'); fi
    else
        UI_INSTALL_PHASES+=('Контейнер Remnawave')
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
        if [[ $gemini == yes ]]; then
            info "  Gemini     Psiphon (${PSIPHON_REGION:-auto}) · 127.0.0.1:$PSIPHON_PORT"
        fi
    elif [[ $ENABLE_SECURITY == no || -z $PANEL_IPS ]]; then
        info "  В firewall разрешите $NODE_PORT/tcp только с IP панели."
    fi
    info "  Установка  $components"
    printf '\n'
    consent=$(yes_no '  Начать установку?' n) || return
    [[ $consent == yes ]] || { info 'Установка отменена.'; return 0; }
    if [[ $UI_CLEAR == yes ]]; then ui_install_progress "$UI_PROGRESS_DONE"; else ui_screen "$UI_INSTALL_TITLE"; fi
    image=$(node_release_image) || return
    ui_install_phase node_prepare_image "$image" || return
    if [[ $mode == full ]]; then ui_install_phase prepare_security || return; fi
    apply_selected_installation "$scope" "$mode" "$image" || return
    if [[ $gemini == yes ]]; then
        # The loopback service has its own rollback and runs after the network worker commits.
        UI_PROGRESS_DONE=$((${#UI_INSTALL_PHASES[@]} - 1))
        if ! ui_install_phase psiphon_apply_settings "$PSIPHON_REGION" "$PSIPHON_PORT"; then
            warn 'Нода настроена. Повторите настройку Gemini в меню [3] → [5] после подтверждения SSH.'
            if [[ $UI_CLEAR == yes ]]; then ui_network_confirmation; fi
            return 1
        fi
        ui_install_progress "$UI_PROGRESS_DONE"
    fi
    printf '\n'
    ui_section 'Установка завершена'
    if [[ $mode == full && $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status; fi
    show_panel_help
    if [[ $gemini == yes ]]; then
        printf '\n'
        ui_section 'Gemini через Psiphon'
        info '  Откройте [3] → [6] и добавьте шаблон в профиль ноды в Remnawave.'
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
    security_ufw_active || { fail 'Сначала включите UFW через пункт «Защита».'; return 1; }
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
    require_config || return
    if [[ $ENABLE_SECURITY == yes ]] && ! security_ufw_active; then
        fail 'Включите управляемый UFW через пункт «Порты и защита».'
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

backup_scope() {
    local scope='config'
    if [[ -n $NODE_PORT ]]; then scope+=' node'; fi
    if [[ $ENABLE_SECURITY == yes || $ENABLE_TRAFFIC_GUARD == yes ]]; then scope+=' network'; fi
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
    if [[ -n $id ]]; then ui_network_confirmation; fi
    if ! load_config && ! load_host_settings; then
        node_status || :
        if psiphon_is_managed; then
            psiphon_status || :
        else
            info 'Начните с мастера или выберите отдельный компонент.'
        fi
        return 0
    fi
    node_status || :
    if [[ $ENABLE_SELFSTEAL == yes ]]; then selfsteal_status || :; fi
    if [[ $ENABLE_SECURITY == yes ]]; then security_status; fi
    if [[ -n $NODE_PORT || -n $VPN_PORTS ]]; then security_vpn_status || :; fi
    bbr_status
    traffic_guard_status
    psiphon_status || :
}

doctor() {
    local result=0 listeners=''
    if ! load_config && ! load_host_settings; then
        if psiphon_is_managed; then psiphon_status; return; fi
        fail 'Сначала настройте ноду или один из компонентов.'
        return 1
    fi
    if [[ -n $NODE_PORT ]]; then node_status required || result=1; fi
    if [[ $ENABLE_SELFSTEAL == yes ]]; then
        selfsteal_status || result=1
        _selfsteal_validate_domain report || result=1
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
        if ! fail2ban-client status sshd >/dev/null 2>&1; then warn 'Fail2Ban для SSH недоступен.'; result=1; fi
    fi
    if [[ $ENABLE_TRAFFIC_GUARD == yes ]]; then traffic_guard_status required || result=1; fi
    if psiphon_is_managed; then psiphon_status || result=1; fi
    security_os_updates_status
    bbr_status
    df -h -- "$STATE_DIR" "$BACKUP_DIR" || result=1
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
        auto-updates)
            if [[ $# == 2 && $target == status ]]; then auto_update_status; return; fi
            ;;
        psiphon)
            case "$target" in
                status) [[ $# == 2 ]] || return 2; psiphon_status; return ;;
                profile) [[ $# -le 3 ]] || return 2; psiphon_profile "${3-}"; return ;;
            esac
            ;;
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
        auto-updates) [[ $# -le 2 ]] || return 2; auto_update_configure "$target" ;;
        psiphon) [[ $# == 1 ]] || return 2; psiphon_configure ;;
        rollback) release_rollback ;;
        update)
            case "$target" in
                tool) [[ $# -le 3 ]] || return 2; release_update "${3-}" ;;
                node) [[ $# == 2 ]] || return 2; update_node force ;;
                all) [[ $# == 2 ]] || return 2; update_all manual ;;
                psiphon) [[ $# == 2 ]] || return 2; psiphon_update ;;
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
