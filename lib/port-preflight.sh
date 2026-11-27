#!/usr/bin/env bash

check_probe_destination() {
    local address=${1,,}
    address=${address%.}
    if valid_domain "$address"; then
        printf '%s\n' "$address"
    elif address=$(normalize_ips "$address" 2>/dev/null) && [[ -n $address && $address != *' '* ]]; then
        printf '%s\n' "$address"
    else
        fail 'Введите IP или домен из карточки ноды в Remnawave.'
    fi
}

port_preflight() {
    local mode=$1 node_port=$2 vpn_ports=$3 source_ips=$4 destination=$5
    local entry port protocol options listeners label result=0 active xray_ports running_node=no
    local -a ports=("$node_port/tcp") probe_ports=() probe_udp=() busy_ports=() selected=()
    local -A seen=()
    read -r -a selected <<< "$vpn_ports"
    ports+=("${selected[@]}")
    if [[ $ENABLE_SELFSTEAL == yes ]]; then ports+=('80/tcp'); fi
    ports+=('8443/tcp')
    xray_ports=$(security_detect_vpn_ports) || return

    ui_section 'Локальные порты'
    for entry in "${ports[@]}"; do
        if [[ -n ${seen[$entry]+x} ]]; then continue; fi
        seen[$entry]=1
        port=${entry%/*}
        protocol=${entry#*/}
        label=VPN
        if [[ $entry == "$node_port/tcp" ]]; then
            label='панель → нода'
        elif [[ $entry == 8443/tcp && ( $ENABLE_SELFSTEAL == yes || " $vpn_ports " != *' 8443/tcp '* ) ]]; then
            label='локальный self-steal'
        elif [[ $entry == 80/tcp && $ENABLE_SELFSTEAL == yes ]]; then
            label='HTTP для сертификата'
        fi
        if [[ $protocol == udp ]]; then options=-lHnup; else options=-lHntp; fi
        listeners=$(ss "$options" "sport = :$port") || return
        if [[ -z $listeners ]]; then
            info "  $entry · $label · свободен"
            if [[ $protocol == tcp && $label != 'локальный self-steal' ]]; then
                probe_ports+=("$port")
            elif [[ $protocol == udp ]]; then
                probe_udp+=("$port")
            fi
        else
            info "  $entry · $label · слушает"
            if [[ $entry == "$node_port/tcp" ]] && _node_owns_listeners "$listeners" &&
               { if declare -F node_any_verify >/dev/null; then node_any_verify; else node_verify; fi; }; then
                running_node=yes
            fi
            if [[ $protocol == tcp && $label == VPN ]]; then
                busy_ports+=("$port")
            fi
            if [[ $mode == install && $label == VPN && " $xray_ports " != *" $entry "* ]]; then
                fail "Порт $entry занят другим сервисом. Укажите свободный порт в профиле Remnawave."
                result=1
            fi
        fi
    done
    (( result == 0 )) || return "$result"

    if [[ $UI_INTERACTIVE != yes ]]; then
        info 'Внешний обмен не проверялся. Запустите preflight в терминале для проверки с панели.'
        return 0
    fi
    if (( ${#probe_ports[@]} == 0 && ${#probe_udp[@]} == 0 && ${#busy_ports[@]} == 0 )) && [[ $running_node == no ]]; then
        info '  Для внешнего теста нужен хотя бы один открытый TCP или UDP порт.'
        return 0
    fi

    if [[ -n ${SSH_PANEL_PROBE_HOST:-} ]]; then
        info "  Тест автоматически запустится с панели для $SSH_PANEL_PROBE_HOST."
        active=$(yes_no '  Запустить проверку с панели?' y) || return
    else
        info '  Ручная проверка.'
        info '  С компьютера · rns (или remna-ssh --panel)'
        active=$(yes_no '  Показать команду для ручной проверки?' n) || return
    fi
    if [[ $active != yes ]]; then info '  Внешний обмен не проверялся.'; return 0; fi
    if [[ -n ${SSH_PANEL_PROBE_HOST:-} ]]; then
        local tls=0 udp_csv busy_csv
        local -a extra_args=()
        if (( ${#probe_ports[@]} + ${#probe_udp[@]} + ${#busy_ports[@]} > 24 )); then
            fail 'Автоматическая проверка принимает до 24 портов за раз.'
            return 1
        fi
        if [[ $running_node == yes ]]; then tls=$node_port; fi
        if (( ${#probe_ports[@]} > 0 || ${#probe_udp[@]} > 0 || ${#busy_ports[@]} > 0 )); then
            if [[ -z $source_ips ]]; then source_ips=$(ask_panel_ips '') || return; fi
            source_ips=$(check_panel_ips "$source_ips") || return
        fi
        if (( ${#probe_udp[@]} > 0 )); then
            udp_csv=$(IFS=,; printf '%s' "${probe_udp[*]}")
            extra_args+=(--udp "$udp_csv")
        fi
        if (( ${#busy_ports[@]} > 0 )); then
            busy_csv=$(IFS=,; printf '%s' "${busy_ports[*]}")
            extra_args+=(--busy "$busy_csv")
        fi
        if ! python3 "$PROJECT_DIR/lib/port-probe.py" --launcher "$SSH_MENU_TICKET" "$tls" \
            "${extra_args[@]}" "$SSH_PANEL_PROBE_HOST" "$source_ips" "${probe_ports[@]}"; then
            ui_attention 'Проверка с панели на ноду не пройдена.'
            return 1
        fi
        if [[ -n $source_ips ]]; then
            info '  Проверка обратного маршрута нода → панель:'
            # shellcheck disable=SC2086 # Space-separated normalized IPs from check_panel_ips.
            python3 "$PROJECT_DIR/lib/port-probe.py" --outbound $source_ips || :
        fi
        if [[ $mode == install ]]; then ui_pause 'продолжить'; fi
        return
    fi
    if [[ -z $destination ]]; then
        destination=$(python3 "$PROJECT_DIR/lib/selfsteal-dns.py" --public-ips 2>/dev/null) || destination=
        destination=${destination%%,*}
    fi
    destination=$(wizard_input 'IP или домен из карточки ноды' "$destination" check_probe_destination) || return
    if [[ $running_node == yes ]]; then
        local endpoint=$destination
        if [[ $endpoint == *:* ]]; then endpoint="[$endpoint]"; fi
        info '  Для TLS работающей ноды выполните на сервере панели:'
        printf '  timeout 10 openssl s_client -connect %s:%s -brief </dev/null\n' "$endpoint" "$node_port"
        info '  Вывод версии TLS показывает, что обмен с сервисом начался.'
    fi
    if (( ${#probe_ports[@]} == 0 && ${#probe_udp[@]} == 0 )); then
        if [[ $mode == install ]]; then ui_pause 'продолжить'; fi
        return
    fi
    if [[ -z $source_ips ]]; then source_ips=$(ask_panel_ips '') || return; fi
    source_ips=$(check_panel_ips "$source_ips") || return
    info "  Источники для теста · $source_ips"
    local -a manual_extra=()
    if (( ${#probe_udp[@]} > 0 )); then
        manual_extra=(--udp "$(IFS=,; printf '%s' "${probe_udp[*]}")")
    fi
    if ! python3 "$PROJECT_DIR/lib/port-probe.py" "${manual_extra[@]}" "$destination" "$source_ips" "${probe_ports[@]}"; then
        ui_attention 'Обмен не подтверждён. Проверьте адрес и firewall VPS или провайдера.'
        return 1
    fi
    info '  Проверка обратного маршрута нода → панель:'
    # shellcheck disable=SC2086 # Space-separated normalized IPs from check_panel_ips.
    python3 "$PROJECT_DIR/lib/port-probe.py" --outbound $source_ips || :
    if [[ $mode == install ]]; then ui_pause 'продолжить'; fi
}

standalone_port_preflight() {
    local default_vpn='' port detected_vpn='' has_external=no
    if [[ -e $CONFIG_DIR/node.json ]]; then
        load_config || return
    else
        _standalone_load || return
        if declare -F _node_external_inspect >/dev/null && ! _node_owned_config && _node_external_inspect; then
            has_external=yes
            if valid_port "${_NODE_EXT_PORT:-}"; then NODE_PORT=$_NODE_EXT_PORT; fi
        fi
        if [[ -z $NODE_DOMAIN ]] && declare -F _selfsteal_external_detect >/dev/null && _selfsteal_external_detect; then
            has_external=yes
            NODE_DOMAIN=$_SELFSTEAL_EXT_DOMAIN
        fi
        if [[ -z $PANEL_IPS && -n $NODE_PORT ]] && declare -F security_ufw_panel_ips_for_port >/dev/null; then
            PANEL_IPS=$(security_ufw_panel_ips_for_port "$NODE_PORT" 2>/dev/null || :)
        fi
        if [[ $has_external == yes ]]; then
            detected_vpn=$(security_detect_vpn_ports 2>/dev/null || :)
        fi
    fi
    NODE_PORT=${NODE_PORT:-2222}
    if [[ $UI_INTERACTIVE == yes ]]; then
        NODE_PORT=$(wizard_input 'Node Port из карточки ноды' "$NODE_PORT" check_node_port) || return
    fi
    for port in 443 9443; do
        if [[ $port != "$NODE_PORT" && $port != "${SSH_PORT:-22}" ]]; then default_vpn+=${default_vpn:+ }$port/tcp; fi
    done
    default_vpn=${VPN_PORTS:-${detected_vpn:-$default_vpn}}
    if [[ $UI_INTERACTIVE == yes ]]; then
        VPN_PORTS=$(wizard_input 'Порты VPN (TCP/UDP)' "${default_vpn:-нет}" security_normalize_vpn_ports) || return
    else
        VPN_PORTS=$(security_normalize_vpn_ports "$default_vpn") || return
    fi
    port_preflight standalone "$NODE_PORT" "$VPN_PORTS" "$PANEL_IPS" "$NODE_DOMAIN"
}
