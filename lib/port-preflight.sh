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
    local -a ports=("$node_port/tcp") probe_ports=() selected=()
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
            if [[ $protocol == tcp && $label != 'локальный self-steal' ]]; then probe_ports+=("$port"); fi
        else
            info "  $entry · $label · слушает"
            if [[ $entry == "$node_port/tcp" ]] && _node_owns_listeners "$listeners" && node_verify; then running_node=yes; fi
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
    if (( ${#probe_ports[@]} == 0 )) && [[ $running_node == no ]]; then
        info '  Для внешнего теста нужен свободный TCP-порт.'
        return 0
    fi

    info '  Тест проверит свободные TCP-порты. Понадобится терминал панели.'
    active=$(yes_no '  Запустить проверку с панели?' y) || return
    if [[ $active != yes ]]; then info '  Внешний обмен не проверялся.'; return 0; fi
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
    if (( ${#probe_ports[@]} == 0 )); then
        if [[ $mode == install ]]; then ui_pause 'продолжить'; fi
        return
    fi
    if [[ -z $source_ips ]]; then source_ips=$(ask_panel_ips '') || return; fi
    source_ips=$(check_panel_ips "$source_ips") || return
    info "  Источники для теста · $source_ips"
    if ! python3 "$PROJECT_DIR/lib/port-probe.py" "$destination" "$source_ips" "${probe_ports[@]}"; then
        ui_attention 'Обмен не подтверждён. Проверьте адрес и firewall VPS или провайдера.'
        return 1
    fi
    if [[ $mode == install ]]; then ui_pause 'продолжить'; fi
}

standalone_port_preflight() {
    local default_vpn='' port
    if [[ -e $CONFIG_DIR/node.json ]]; then load_config || return; else _standalone_load || return; fi
    NODE_PORT=${NODE_PORT:-2222}
    if [[ $UI_INTERACTIVE == yes ]]; then
        NODE_PORT=$(wizard_input 'Node Port из карточки ноды' "$NODE_PORT" check_node_port) || return
    fi
    for port in 443 9443; do
        if [[ $port != "$NODE_PORT" && $port != "${SSH_PORT:-22}" ]]; then default_vpn+=${default_vpn:+ }$port/tcp; fi
    done
    default_vpn=${VPN_PORTS:-$default_vpn}
    if [[ $UI_INTERACTIVE == yes ]]; then
        VPN_PORTS=$(wizard_input 'Порты VPN (TCP/UDP)' "${default_vpn:-нет}" security_normalize_vpn_ports) || return
    else
        VPN_PORTS=$(security_normalize_vpn_ports "$default_vpn") || return
    fi
    port_preflight standalone "$NODE_PORT" "$VPN_PORTS" "$PANEL_IPS" "$NODE_DOMAIN"
}
