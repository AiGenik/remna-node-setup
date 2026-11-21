#!/usr/bin/env bash
# Configuration fields are shared with the node wizard and security functions.
# shellcheck disable=SC2034

load_host_settings() {
    local file=$CONFIG_DIR/host.json data
    local -a fields
    [[ -e $file || -L $file ]] || return 1
    if [[ -L $file || ! -f $file ]] || ! data=$(jq -er '
      if .schema == 1
        and (.node_domain | type) == "string"
        and (.admin_ips | type) == "string"
        and ((.ssh_port == null) or (.ssh_port | type) == "number")
        and ((.security // "yes") == "yes" or .security == "no")
        and ((.vpn_ports // "") | type) == "string"
        and (.selfsteal_server == "caddy" or .selfsteal_server == "nginx")
        and ([.selfsteal, .bbr, .traffic_guard] | all(. == "yes" or . == "no"))
      then [.node_domain, (.ssh_port // ""), .admin_ips, .selfsteal, .selfsteal_server, .bbr, .traffic_guard,
            (.vpn_ports // ""), (.security // (if .ssh_port != null then "yes" else "no" end))] | .[]
      else error("invalid host configuration")
      end' "$file" 2>/dev/null); then
        fail "Не удалось прочитать настройки сервера из $file."
        return 2
    fi
    mapfile -t fields <<< "$data"
    if [[ ${#fields[@]} != 9 ]] ||
        { [[ -n ${fields[1]} ]] && ! valid_port "${fields[1]}"; } ||
        { [[ ${fields[3]} == yes || -n ${fields[0]} ]] && ! valid_domain "${fields[0]}"; }; then
        fail "Проверьте настройки сервера в $file."
        return 2
    fi
    NODE_DOMAIN=${fields[0]}
    NODE_PORT=
    PANEL_IPS=
    SSH_PORT=${fields[1]}
    ADMIN_IPS=${fields[2]}
    ENABLE_SELFSTEAL=${fields[3]}
    SELFSTEAL_SERVER=${fields[4]}
    ENABLE_BBR=${fields[5]}
    ENABLE_TRAFFIC_GUARD=${fields[6]}
    VPN_PORTS=${fields[7]}
    ENABLE_SECURITY=${fields[8]}
    VPN_PORTS_SAVED=yes
}

_standalone_load() {
    local file=$CONFIG_DIR/host.json
    if [[ -e $file || -L $file ]]; then
        load_host_settings
        return
    fi
    NODE_DOMAIN=
    NODE_PORT=
    PANEL_IPS=
    SSH_PORT=
    ADMIN_IPS=
    ENABLE_SELFSTEAL=no
    SELFSTEAL_SERVER=caddy
    ENABLE_BBR=no
    ENABLE_TRAFFIC_GUARD=no
    ENABLE_SECURITY=no
    VPN_PORTS=
    VPN_PORTS_SAVED=no
}

_standalone_save() {
    local tmp
    tmp=$(mktemp "$CONFIG_DIR/.host.XXXXXX") || return
    if ! jq -n --arg domain "$NODE_DOMAIN" --argjson ssh "${SSH_PORT:-null}" --arg admin "$ADMIN_IPS" \
        --arg selfsteal "$ENABLE_SELFSTEAL" --arg webserver "$SELFSTEAL_SERVER" \
        --arg bbr "$ENABLE_BBR" --arg traffic "$ENABLE_TRAFFIC_GUARD" \
        --arg security "$ENABLE_SECURITY" --arg vpn "$VPN_PORTS" \
        '{schema:1,node_domain:$domain,ssh_port:$ssh,admin_ips:$admin,
          selfsteal:$selfsteal,selfsteal_server:$webserver,bbr:$bbr,traffic_guard:$traffic,
          security:$security,vpn_ports:$vpn}' > "$tmp" ||
        ! mv -f -- "$tmp" "$CONFIG_DIR/host.json"; then
        rm -f -- "$tmp"
        return 1
    fi
}

_standalone_access() {
    local detected
    get_admin_ip || return
    detected=$(detect_ssh_port "$SSH_PORT") || return
    if [[ ${UI_INTERACTIVE:-no} == yes ]]; then
        info '  Enter оставит предложенные настройки SSH.'
        SSH_PORT=$(wizard_input 'SSH-порт VPS' "${detected:-22}" check_ssh_port "$detected") || return
        ADMIN_IPS=$(wizard_input 'Доверенные IP или подсети' "${ADMIN_IPS:-$ADMIN_IP}" normalize_ips network) || return
    else
        if ! valid_port "$detected"; then
            fail 'SSH-порт не определён. Запустите настройку защиты из терминала.'
            return 1
        fi
        SSH_PORT=$detected
        ADMIN_IPS=${ADMIN_IPS:-$ADMIN_IP}
    fi
}

_standalone_apply_security() {
    ui_run 'Пакеты и правила UFW / Fail2Ban' security_apply_current && _standalone_save
}

standalone_security() {
    local consent
    _standalone_load && apt_install_missing python3 && _standalone_access || return
    if [[ ${UI_INTERACTIVE:-no} == yes ]]; then
        VPN_PORTS=$(security_prompt_vpn_ports "$VPN_PORTS") || return
        security_preflight || return
        info "  UFW разрешит SSH на порту $SSH_PORT. Для остальных входящих соединений применяется запрет по умолчанию."
        if [[ -n $VPN_PORTS ]]; then info "  Публичные порты — $VPN_PORTS."; fi
        if [[ $ENABLE_SELFSTEAL == yes ]]; then info '  TCP 80 останется доступен для сертификата.'; fi
        consent=$(yes_no '  Включить UFW и Fail2Ban?' n) || return
        [[ $consent == yes ]] || return 0
    else
        security_preflight || return
    fi
    ENABLE_SECURITY=yes
    prepare_security || return
    run_change 'config network' _standalone_apply_security
}

_standalone_apply_bbr() {
    bbr_apply || return
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr &&
        $(sysctl -n net.core.default_qdisc 2>/dev/null) == fq ]]; then
        ENABLE_BBR=yes
    else
        ENABLE_BBR=no
    fi
    _standalone_save
}

standalone_bbr() {
    _standalone_load || return
    run_change 'config bbr' _standalone_apply_bbr
}

_standalone_apply_traffic_guard() {
    ui_run 'Применение базы TrafficGuard' traffic_guard_apply "$1" && _standalone_save
}

standalone_traffic_guard() {
    local consent
    _standalone_load || return
    if ! security_ufw_active; then
        fail 'Сначала включите UFW в разделе «Порты и защита».'
        return 1
    fi
    apt_install_missing ca-certificates curl python3 ipset iptables && get_admin_ip || return
    if [[ -z ${ADMIN_IP:-}${ADMIN_IPS:-} && ${UI_INTERACTIVE:-no} == yes ]]; then
        ADMIN_IPS=$(wizard_input 'Ваш доверенный IP для SSH' '' normalize_ips network) || return
    fi
    if [[ -z ${ADMIN_IP:-}${ADMIN_IPS:-} ]]; then
        fail 'Укажите доверенный IP в настройках защиты или запустите TrafficGuard из SSH.'
        return 1
    fi
    ADMIN_IPS=${ADMIN_IPS:-$ADMIN_IP}
    consent=$(yes_no 'Проверить и применить свежую версию и базу TrafficGuard?' n) || return
    [[ $consent == yes ]] || return 0
    ENABLE_TRAFFIC_GUARD=yes
    prepare_and_change_traffic_guard _standalone_apply_traffic_guard
}

_standalone_apply_selfsteal() {
    if [[ $1 == yes ]]; then security_allow_acme || return; fi
    ui_run "HTTPS и сертификат ($SELFSTEAL_SERVER)" selfsteal_apply && _standalone_save || return
    info 'Локальный HTTPS готов на 127.0.0.1:8443.'
}

standalone_selfsteal() {
    local scope='config selfsteal' acme_rule=no
    _standalone_load && release_wait_for_apt &&
        apt_install_missing ca-certificates curl python3 iproute2 || return
    if [[ -z $NODE_DOMAIN || ${UI_INTERACTIVE:-no} == yes ]]; then
        info '  Домен должен указывать на публичный IP этого VPS. Для Cloudflare используйте DNS only.'
        NODE_DOMAIN=$(wizard_input 'Домен self-steal' "$NODE_DOMAIN" check_node_domain) || return
    fi
    SELFSTEAL_SERVER=$(select_selfsteal_server "$SELFSTEAL_SERVER" "${1-}") || return
    ENABLE_SELFSTEAL=yes
    selfsteal_preflight || return
    if security_ufw_managed; then
        acme_rule=yes
        scope+=' network'
    elif security_ufw_active; then
        info 'Проверьте, что действующие правила UFW пропускают TCP 80 для выпуска сертификата.'
    fi
    release_wait_for_apt || return
    run_change "$scope" _standalone_apply_selfsteal "$acme_rule"
}
