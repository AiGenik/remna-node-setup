#!/usr/bin/env bash

vpn_port_read() {
    jq -er '
        def port: type == "number" and . == floor and . > 0 and . <= 65535;
        select((.old | port) and (.new | port) and (.old != .new) and
               (.was_open == "yes" or .was_open == "no") and
               (.was_blocked == "yes" or .was_blocked == "no"))
        | [.old, .new, .was_open, .was_blocked] | @tsv
    ' "$CONFIG_DIR/vpn-port.json"
}

vpn_port_owned_rules() {
    local port=$1 kind=$2 rules
    rules=$(LC_ALL=C ufw status numbered) || return
    sed -nE "s/^\[ *([0-9]+)\][[:space:]]+$port\/tcp( \(v6\))?[[:space:]].*# remna-node-setup:$kind([[:space:]]|$).*/\1/p" <<< "$rules" |
        sort -rn
}

vpn_port_delete_owned() {
    local numbers number
    numbers=$(vpn_port_owned_rules "$1" "$2") || return
    while IFS= read -r number; do
        [[ -n $number ]] || continue
        ufw --force delete "$number" || return
    done <<< "$numbers"
}

vpn_port_block() {
    local port=$1 before after
    vpn_port_delete_owned "$port" vpn || return
    before=$(LC_ALL=C ufw show added) || return
    ufw prepend deny in proto tcp to any port "$port" comment remna-node-setup:vpn-closed || return
    after=$(LC_ALL=C ufw show added) || return
    # UFW can replace an identical rule in place. Roll back if it rewrote a
    # rule we did not own instead of adding our more specific denial.
    after=$(sed -E "/^ufw deny $port\/tcp comment 'remna-node-setup:vpn-closed'$/d" <<< "$after") || return
    if [[ $before != "$after" ]]; then
        fail "UFW попытался изменить существующее правило для $port/tcp. Проверьте ручные правила."
        return 1
    fi
}

vpn_port_is_listening() {
    local sockets
    sockets=$(ss -H -ltn "sport = :$1") || return 2
    [[ -n $sockets ]]
}

vpn_port_require_idle() {
    local result=0
    vpn_port_is_listening "$1" || result=$?
    case $result in
        1) return 0 ;;
        0) fail "На $1/tcp ещё есть слушающий сервис. Освободите порт и повторите." ;;
        *) fail "Не удалось проверить сокеты $1/tcp." ;;
    esac
}

_vpn_port_save_state() {
    if [[ ${_VPN_PORT_LEGACY_MODE:-no} == yes ]] && declare -F _standalone_save >/dev/null; then
        _standalone_save
    else
        save_config
    fi
}

_vpn_port_legacy_init() {
    local detected='' rules='' rule_ports=''
    if ! security_ufw_active || ! security_ufw_has_deny_incoming; then
        fail 'Сначала запустите мастер установки или настройте UFW с политикой deny incoming.'
        return 1
    fi
    if ! declare -F _standalone_load >/dev/null || ! _standalone_load; then
        return 1
    fi
    _VPN_PORT_LEGACY_MODE=yes
    ENABLE_SECURITY=yes
    get_admin_ip || :
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    if [[ -z $SSH_PORT ]]; then
        SSH_PORT=$(detect_ssh_port 2>/dev/null || :)
    fi
    if [[ -z $NODE_PORT ]] && declare -F _node_external_inspect >/dev/null && _node_external_inspect; then
        if valid_port "${_NODE_EXT_PORT:-}"; then NODE_PORT=$_NODE_EXT_PORT; fi
    fi
    if [[ -z $NODE_DOMAIN ]] && declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; then
        NODE_DOMAIN=$_SELFSTEAL_EXT_DOMAIN
        # shellcheck disable=SC2034 # Consumed by _standalone_save in lib/standalone.sh.
        SELFSTEAL_SERVER=$_SELFSTEAL_EXT_SERVER
    fi
    if [[ -z $PANEL_IPS && -n $NODE_PORT ]] && declare -F security_ufw_panel_ips_for_port >/dev/null; then
        PANEL_IPS=$(security_ufw_panel_ips_for_port "$NODE_PORT" 2>/dev/null || :)
    fi
    if [[ -n $PANEL_IPS ]] && ! normalize_ips "$PANEL_IPS" >/dev/null 2>&1; then
        PANEL_IPS=
    fi
    if [[ -z $PANEL_IPS ]]; then
        NODE_PORT=
    fi
    if [[ -z $VPN_PORTS ]]; then
        detected=$(security_detect_vpn_ports 2>/dev/null || :)
        rules=$(LC_ALL=C ufw status 2>/dev/null || :)
        rule_ports=$(awk -v ssh="${SSH_PORT:-22}" -v node="${NODE_PORT:-}" '
            $0 !~ /\(v6\)/ && $0 ~ /[[:space:]]ALLOW([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)/ {
                p = $1
                proto = "tcp"
                if (p ~ /\//) { split(p, a, "/"); p = a[1]; proto = a[2] }
                if (p ~ /^[0-9]+$/ && p != 80 && p != ssh && p != node) {
                    item = p "/" proto
                    if (!seen[item]++) out = (out ? out " " : "") item
                }
            }
            END { if (out != "") print out }
        ' <<< "$rules")
        VPN_PORTS=$(security_normalize_vpn_ports "${detected:-} ${rule_ports:-}" 2>/dev/null || printf '%s\n' "${detected:-}")
        # shellcheck disable=SC2034 # Consumed by security_prompt_vpn_ports in lib/security.sh.
        VPN_PORTS_SAVED=yes
    fi
}

vpn_port_require_firewall() {
    _VPN_PORT_LEGACY_MODE=no
    if ! require_config 2>/dev/null; then
        if [[ -e $CONFIG_DIR/node.json ]]; then
            require_config
            return
        fi
        _vpn_port_legacy_init || return
    fi
    if [[ $ENABLE_SECURITY != yes ]] || ! security_ufw_active; then
        fail 'Сначала настройте UFW через [2] → [3] «Порты, UFW и защита SSH».'
        return 1
    fi
    security_preflight
}

vpn_port_apply_prepare() {
    local old=$1 new=$2 was_open=$3 was_blocked=$4 rules
    vpn_port_require_idle "$new" || return
    vpn_port_delete_owned "$new" vpn-closed || return
    security_allow_vpn_ports "$new/tcp" || return
    rules=$(LC_ALL=C ufw status) || return
    security_ufw_public_rule "$new/tcp" "$rules" || { fail "Разрешение $new/tcp в UFW не подтверждено."; return 1; }
    security_ufw_set_boot enabled || return
    VPN_PORTS+=" $new/tcp"
    _vpn_port_save_state || return
    jq -n --argjson old "$old" --argjson new "$new" --arg was_open "$was_open" --arg was_blocked "$was_blocked" \
        '{$old,$new,$was_open,$was_blocked}' > "$CONFIG_DIR/vpn-port.json"
}

vpn_port_prepare() {
    local old=$1 new=$2 detected rules blocked was_open=no was_blocked=no
    if ! valid_port "$old" || ! valid_port "$new" || [[ $old == "$new" ]]; then
        fail 'Укажите два разных номера TCP-портов.'
        return 1
    fi
    vpn_port_require_firewall || return
    [[ ! -e $CONFIG_DIR/vpn-port.json ]] || { fail 'Сначала завершите или отмените текущий перенос.'; return 1; }
    [[ " $VPN_PORTS " == *" $old/tcp "* && " $VPN_PORTS " != *" $new/tcp "* ]] ||
        { fail 'Старый порт должен быть в списке VPN, а новый — ещё не добавлен.'; return 1; }
    security_normalize_vpn_ports "$new/tcp" >/dev/null || return
    detected=$(security_detect_vpn_ports) || return
    [[ " $detected " == *" $old/tcp "* ]] || { fail "Xray не слушает выбранный порт $old/tcp."; return 1; }
    vpn_port_require_idle "$new" || return
    rules=$(LC_ALL=C ufw status) || return
    if security_ufw_public_rule "$new/tcp" "$rules"; then was_open=yes; fi
    blocked=$(vpn_port_owned_rules "$new" vpn-closed) || return
    if [[ -n $blocked ]]; then was_blocked=yes; fi
    run_change 'config network' vpn_port_apply_prepare "$old" "$new" "$was_open" "$was_blocked" || return
    info '  Подтвердите SSH и снова откройте «Сменить порт VPN». Там будут шаги для панели.'
}

vpn_port_instructions() {
    info "  Remnawave → Config Profiles → профиль ноды → inbounds: замените port $1 на $2."
    info '  Если профиль общий, выделите этой ноде отдельный профиль или inbound.'
    info '  Чтобы оба порта принимали клиентов, добавьте новый inbound с отдельным тегом и Host.'
    info "  В Hosts укажите $2, обновите подписку и подключитесь тестовым клиентом."
    info '  Если у провайдера есть firewall, добавьте новый TCP-порт там.'
    info '  Затем снова откройте «Сменить порт VPN».'
}

vpn_port_list_without() {
    local removed=$1 entry result=''
    local -a entries=()
    read -r -a entries <<< "$VPN_PORTS"
    for entry in "${entries[@]}"; do
        if [[ $entry != "$removed/tcp" ]]; then result+=${result:+ }$entry; fi
    done
    printf '%s\n' "$result"
}

vpn_port_apply_finish() {
    local old=$1 new=$2 close=$3 refresh=$4
    vpn_port_verify_target "$new" || return
    if [[ $close == close ]]; then
        vpn_port_require_idle "$old" && vpn_port_block "$old" || return
    fi
    _vpn_port_save_state || return
    if [[ $refresh == yes ]]; then
        selfsteal_refresh_redirect && selfsteal_verify || return
    fi
    if [[ ${_VPN_PORT_LEGACY_MODE:-no} == yes ]] && declare -F _selfsteal_external_detect >/dev/null &&
       _selfsteal_external_detect && [[ $_SELFSTEAL_EXT_SERVER == nginx && $new != 443 ]]; then
        warn "Проверьте порт HTTPS-редиректа в внешнем $_SELFSTEAL_EXT_CONFIG (если нужен $new вместо 443)."
    fi
    rm -- "$CONFIG_DIR/vpn-port.json"
    info "VPN-порт: $new/tcp. Старый $old/tcp $([[ $close == close ]] && printf закрыт || printf сохранён)."
}

vpn_port_verify_target() {
    local port=$1 detected rules
    detected=$(security_detect_vpn_ports) || return
    rules=$(LC_ALL=C ufw status) || return
    if [[ " $detected " != *" $port/tcp "* ]] || ! security_ufw_public_rule "$port/tcp" "$rules"; then
        fail "Xray и UFW ещё не готовы на $port/tcp. Проверьте профиль и Host в Remnawave."
        return 1
    fi
}

vpn_port_finish() {
    local close=$1 state old new scope='config network' refresh=no entry result='' redirect
    local -a entries=()
    vpn_port_require_firewall || return
    state=$(vpn_port_read) || return
    IFS=$'\t' read -r old new _ _ <<< "$state"
    vpn_port_verify_target "$new" || return
    if [[ " $VPN_PORTS " != *" $old/tcp "* || " $VPN_PORTS " != *" $new/tcp "* ]]; then
        fail 'Список VPN-портов изменился после начала переноса. Восстановите оба порта или отмените перенос.'
        return 1
    fi
    if [[ $close == close ]]; then vpn_port_require_idle "$old" || return; fi
    redirect=$(selfsteal_public_port) || return
    read -r -a entries <<< "$VPN_PORTS"
    for entry in "${entries[@]}"; do
        case $entry in
            "$old/tcp") entry=$new/tcp ;;
            "$new/tcp") continue ;;
        esac
        result+=${result:+ }$entry
    done
    if [[ $close == keep ]]; then result+=" $old/tcp"; fi
    VPN_PORTS=$result
    if [[ $ENABLE_SELFSTEAL == yes && $redirect != "$(selfsteal_public_port)" ]]; then
        selfsteal_verify || { fail 'Сначала восстановите работу self-steal.'; return 1; }
        scope+=' selfsteal'
        refresh=yes
    fi
    run_change "$scope" vpn_port_apply_finish "$old" "$new" "$close" "$refresh"
}

vpn_port_apply_cancel() {
    local new=$1 was_open=$2 was_blocked=$3
    vpn_port_require_idle "$new" || return
    if [[ $was_blocked == yes ]]; then
        vpn_port_block "$new" || return
    elif [[ $was_open == no ]]; then
        vpn_port_delete_owned "$new" vpn || return
    fi
    VPN_PORTS=$(vpn_port_list_without "$new") || return
    _vpn_port_save_state && rm -- "$CONFIG_DIR/vpn-port.json"
}

vpn_port_cancel() {
    local state new was_open was_blocked
    vpn_port_require_firewall || return
    state=$(vpn_port_read) || return
    IFS=$'\t' read -r _ new was_open was_blocked <<< "$state"
    run_change 'config network' vpn_port_apply_cancel "$new" "$was_open" "$was_blocked"
}

vpn_port_close_retired() {
    local port=$1
    vpn_port_require_idle "$port" && vpn_port_block "$port" || return
    VPN_PORTS=$(vpn_port_list_without "$port") || return
    _vpn_port_save_state
}

vpn_port_close() {
    local port=$1
    valid_port "$port" || { fail 'Укажите номер TCP-порта.'; return 1; }
    vpn_port_require_firewall || return
    [[ ! -e $CONFIG_DIR/vpn-port.json && " $VPN_PORTS " == *" $port/tcp "* ]] ||
        { fail 'Сначала завершите перенос. Закрывать можно только сохранённый VPN-порт.'; return 1; }
    if [[ $ENABLE_SELFSTEAL == yes && $(selfsteal_public_port) == "$port" ]]; then
        fail 'Этот порт ещё используется в перенаправлении self-steal.'
        return 1
    fi
    vpn_port_require_idle "$port" || return
    run_change 'config network' vpn_port_close_retired "$port"
}

vpn_port_profile() {
    local old=$1 new=$2
    if ! valid_port "$old" || ! valid_port "$new" || [[ $old == "$new" ]]; then
        fail 'Укажите два разных номера TCP-портов.'
        return 1
    fi
    jq -e --arg old "$old" --arg new "$new" '
        if (.inbounds | type) != "array" then error("В JSON отсутствует массив inbounds.")
        elif ([.inbounds[] | select((.port | tostring) == $old)] | length) != 1
            then error("Старый порт должен встречаться ровно в одном inbound.")
        elif any(.inbounds[]; (.port | tostring) == $new)
            then error("Новый порт уже используется в профиле.")
        else .inbounds |= map(if (.port | tostring) == $old then .port = ($new | tonumber) else . end)
        end
    '
}

vpn_port_wizard() {
    local state old new detected choice confirm mode=keep
    vpn_port_require_firewall || return
    if [[ -e $CONFIG_DIR/vpn-port.json ]]; then
        state=$(vpn_port_read) || return
        IFS=$'\t' read -r old new _ _ <<< "$state"
        info "  Перенос $old → $new/tcp"
        vpn_port_instructions "$old" "$new"
        info '  [1] Завершить перенос  [2] Отменить'
        choice=$(prompt '  Действие →') || return
        case $choice in
            1)
                confirm=$(yes_no "  Проверили VPN-клиентом порт $new?" n) || return
                [[ $confirm == yes ]] || return 0
                confirm=$(yes_no "  Закрыть старый порт $old/tcp в UFW?" n) || return
                if [[ $confirm == yes ]]; then mode=close; fi
                vpn_port_finish "$mode"
                ;;
            2)
                confirm=$(yes_no "  Отменить подготовку $new/tcp?" n) || return
                [[ $confirm == yes ]] || return 0
                vpn_port_cancel
                ;;
        esac
        return
    fi
    detected=$(security_detect_vpn_ports) || return
    info "  В UFW · ${VPN_PORTS:-нет}"
    info "  Слушает Xray · ${detected:-нет}"
    info '  [1] Подготовить новый порт  [2] Закрыть неиспользуемый'
    choice=$(prompt '  Действие →') || return
    case $choice in
        1)
            old=$(wizard_input 'Текущий TCP-порт' "$(selfsteal_public_port)" valid_port) || return
            new=$(wizard_input 'Новый TCP-порт' '' valid_port) || return
            vpn_port_prepare "$old" "$new"
            ;;
        2)
            old=$(wizard_input 'TCP-порт для закрытия' '' valid_port) || return
            confirm=$(yes_no "  Закрыть $old/tcp?" n) || return
            [[ $confirm == yes ]] || return 0
            vpn_port_close "$old"
            ;;
    esac
}
