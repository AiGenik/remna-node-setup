#!/usr/bin/env bash

update_effects_touch_network() {
    grep -Eq '^(ufw|iptables|ipset|nftables|openssh-server|openssh-sftp-server)$' <<< "$1"
}

update_ufw_rules_fingerprint() {
    # TrafficGuard may insert an empty line when it rewrites its UFW block.
    awk 'NF' "$1" | sha256sum
}

update_firewall_fingerprint() (
    local rules tool
    LC_ALL=C ufw status verbose || return
    sha256sum -- /etc/default/ufw || return
    for rules in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        update_ufw_rules_fingerprint "$rules" || return
    done
    find /etc/ufw -type f ! -path /etc/ufw/before.rules ! -path /etc/ufw/before6.rules \
        -exec sha256sum -- {} + | LC_ALL=C sort || return
    awk '
        $1 ~ /^(create|add)$/ && $2 ~ /^SCANNERS-BLOCK-V[46]$/ { next }
        !/^#/ && NF { print }
    ' /etc/ipset.conf || return
    for tool in iptables-save ip6tables-save; do
        "$tool" | awk '
            /^#/ { next }
            /^:/ { sub(/\[[0-9]+:[0-9]+\]$/, "[0:0]") }
            { print }
        ' || return
    done
)

update_guard_verified() {
    local stage=$1 before=$2 after
    traffic_guard_apply "$stage" || return
    after=$(update_firewall_fingerprint) || return
    if [[ $before != "$after" ]]; then
        fail 'TrafficGuard изменил общие правила firewall. Восстанавливаю снимок.'
        return 1
    fi
}

update_guard_automatic() {
    local stage=$1 before
    if [[ -z ${ADMIN_IPS:-} ]] || ! traffic_guard_firewall_active; then
        warn 'TrafficGuard ждёт ручного обновления. Нужна проверенная защита и доверенный IP SSH.'
        return 0
    fi
    before=$(update_firewall_fingerprint) || return
    run_change network --verified-network update_guard_verified "$stage" "$before"
}

update_guard_needs_apply() {
    [[ -f $1/traffic-guard ]] || ! traffic_guard_verify "$1" 2>/dev/null
}

update_combined_network() {
    local packages=$1 guard=$2
    if [[ -n $packages ]]; then apply_system_package_updates "$packages" || return; fi
    if [[ -n $guard ]]; then traffic_guard_apply "$guard" || return; fi
}

apply_combined_updates() (
    local mode=$1 result=$2 plan='' effects='' pending_packages='' guard_stage='' pending_guard=''
    local configured=no ufw_state=inactive
    if [[ -e $CONFIG_DIR/node.json ]]; then
        load_config || { fail 'Не удалось прочитать настройки ноды.'; return 1; }
        configured=yes
    elif [[ -e $CONFIG_DIR/host.json ]]; then
        load_host_settings || return
        configured=yes
    fi
    if ! plan=$(system_package_update_plan); then
        result=1
        plan=
    fi
    if [[ $mode == auto && -n $plan ]]; then
        local filtered
        filtered=$(awk -F '\t' '$1 !~ /^(ufw|iptables|ipset|nftables|openssh-server|openssh-sftp-server)$/' <<< "$plan") || return
        if [[ $filtered != "$plan" ]]; then
            warn 'Пакеты firewall ждут запуска «Обновить всё» из SSH.'
            plan=$filtered
        fi
    fi
    if [[ -n $plan ]]; then
        if ! effects=$(apt_upgrade_installed_effects "$plan"); then
            result=1
        elif [[ $mode == auto ]] && update_effects_touch_network "$effects"; then
            warn 'Изменение зависимостей firewall ждёт ручного обновления.'
        elif [[ -n $effects ]]; then
            if update_effects_touch_network "$effects" && command -v ufw >/dev/null; then
                if ! ufw_state=$(security_ufw_state); then
                    warn 'Не удалось проверить UFW. Пакеты firewall пропущены.'
                    ufw_state=unknown
                    result=1
                fi
            fi
            printf 'Пакеты APT · %s\n' "$(paste -sd ' ' <<< "$effects")"
            case "$ufw_state" in
                active) pending_packages=$plan ;;
                inactive)
                    ui_run 'Системные пакеты' apply_system_package_updates "$plan" || result=1
                    ;;
            esac
        fi
    else
        info 'Для выбранных пакетов APT обновлений нет.'
    fi

    if [[ $configured == yes && -n $NODE_PORT ]]; then
        if [[ $mode == auto ]] && ! node_verify; then
            warn 'Нода недоступна. Автообновление ноды пропущено.'
        else
            update_node if-needed || result=1
        fi
    fi
    if psiphon_is_managed; then psiphon_update || result=1; fi

    if [[ $configured == yes && $ENABLE_TRAFFIC_GUARD == yes && -s $STATE_DIR/traffic-guard/version ]]; then
        get_admin_ip || return
        guard_stage=$(mktemp -d "$STATE_DIR/.update-guard.XXXXXX") || return
        trap 'rm -rf -- "$guard_stage"' EXIT
        if ! ui_run 'Проверка версии и базы TrafficGuard' traffic_guard_prepare "$guard_stage"; then
            result=1
        elif update_guard_needs_apply "$guard_stage"; then
            if [[ $mode == auto ]]; then
                update_guard_automatic "$guard_stage" || result=1
            else
                pending_guard=$guard_stage
            fi
        else
            info 'TrafficGuard и список сканеров актуальны.'
        fi
    fi

    if [[ -n $pending_packages || -n $pending_guard ]]; then
        run_change network update_combined_network "$pending_packages" "$pending_guard" || result=1
    fi
    if (( result == 0 )); then info 'Обновление завершено.'; else warn 'Есть ошибки обновления. Смотрите вывод выше.'; fi
    return "$result"
)

update_all() {
    local mode=$1 previous current consent result=0
    if [[ $mode == manual && $UI_INTERACTIVE == yes ]]; then
        ui_attention 'Службы могут перезапуститься. Для firewall нужен новый SSH-сеанс.'
        consent=$(yes_no '  Обновить установленные компоненты?' n) || return
        [[ $consent == yes ]] || return 0
    fi
    if [[ -s $CONFIG_DIR/release-repository ]]; then
        previous=$(release_get_optional_link "$RELEASE_ROOT/current") || return
        release_update || result=1
        current=$(release_get_optional_link "$RELEASE_ROOT/current") || return
        if [[ $current != "$previous" ]]; then
            local -a handoff=(__apply-updates "$mode" "$result")
            if [[ -n ${SSH_MENU_TICKET:-} ]]; then handoff+=("$SSH_MENU_TICKET"); fi
            exec "$RELEASE_COMMAND" "${handoff[@]}"
        fi
    else
        info 'Репозиторий скрипта не задан. Обновляю установленные компоненты.'
    fi
    apply_combined_updates "$mode" "$result"
}

_updates_github_tag() {
    local repo=$1 metadata
    metadata=$(curl -fsSL --proto '=https' --connect-timeout 6 --max-time 12 \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || return 1
    jq -er '.tag_name | strings' <<< "$metadata" 2>/dev/null
}

_updates_print_row() {
    local component=$1 current=${2:--} latest=${3:--} status
    if [[ $current == '-' || $current == 'не установлен' ]]; then
        status='—'
    elif [[ $latest == '-' || $latest == 'недоступно' ]]; then
        status='онлайн недоступно'
    elif [[ ${current#v} == "${latest#v}" ]]; then
        status='✓ актуален'
    else
        status='↑ есть обновление'
    fi
    printf '  %-24s %-16s %-16s %s\n' "$component" "$current" "$latest" "$status"
}

show_versions() {
    local tool_cur tool_lat repo='AiGenik/remna-node-setup'
    local node_cur='не установлен' node_lat='недоступно' node_img
    local tg_cur='не установлен' tg_lat='недоступно'
    local psi_cur='не установлен' psi_lat='недоступно' psi_marker
    local pkg pkg_cur pkg_lat

    if [[ -n ${CONFIG_DIR:-} && -s $CONFIG_DIR/release-repository ]]; then
        repo=$(< "$CONFIG_DIR/release-repository")
    fi
    tool_cur=$(version_get version 2>/dev/null || printf 'неизвестно')
    tool_lat=$(_updates_github_tag "$repo" 2>/dev/null || printf 'недоступно')

    if [[ -n ${NODE_DIR:-} && -f $NODE_DIR/compose.yaml ]]; then
        node_img=$(jq -er '.services.remnanode.image // empty' "$NODE_DIR/compose.yaml" 2>/dev/null || :)
        node_cur=$(_node_pinned_image_version "$node_img" 2>/dev/null || :)
        if [[ -z $node_cur ]]; then
            node_cur=${node_img##*:}
            node_cur=${node_cur%%@*}
            node_cur=${node_cur#v}
        fi
        [[ -n $node_cur ]] || node_cur='установлен'
    fi
    if declare -F _node_latest_tag >/dev/null; then
        node_lat=$(_node_latest_tag 2>/dev/null || printf 'недоступно')
        node_lat=${node_lat#v}
    fi

    if [[ -s $STATE_DIR/traffic-guard/version ]]; then
        tg_cur=$(< "$STATE_DIR/traffic-guard/version")
    fi
    tg_lat=$(_updates_github_tag 'dotX12/traffic-guard' 2>/dev/null || printf 'недоступно')
    tg_lat=${tg_lat#v}

    if psi_marker=$(_psiphon_marker 2>/dev/null) && [[ -s $psi_marker ]]; then
        psi_cur=$(jq -r '.version // "установлен"' "$psi_marker" 2>/dev/null || printf 'установлен')
    elif systemctl is-active --quiet vps-psiphon.service 2>/dev/null; then
        psi_cur='сторонний'
    fi
    if declare -F psiphon_latest_version >/dev/null; then
        psi_lat=$(psiphon_latest_version 2>/dev/null || printf 'недоступно')
    fi

    ui_section 'Версии компонентов (установлено / онлайн)'
    printf '  %-24s %-16s %-16s %s\n' 'Компонент' 'Установлено' 'Актуально' 'Статус'
    printf '  %-24s %-16s %-16s %s\n' '────────────────────────' '────────────────' '────────────────' '───────────────'
    _updates_print_row 'remna-node-setup' "${tool_cur#v}" "${tool_lat#v}"
    _updates_print_row 'Remnawave Node / Xray' "$node_cur" "$node_lat"
    _updates_print_row 'TrafficGuard' "$tg_cur" "$tg_lat"
    _updates_print_row 'Psiphon (vps-psiphon)' "$psi_cur" "$psi_lat"
    for pkg in nginx certbot ufw fail2ban docker-ce; do
        pkg_cur=$(apt_installed_version "$pkg" 2>/dev/null || :)
        [[ -n $pkg_cur ]] || continue
        pkg_lat=$(LC_ALL=C apt-cache policy "$pkg" 2>/dev/null | awk '$1 == "Candidate:" {print $2; exit}') || pkg_lat='-'
        pkg_cur=${pkg_cur%%+*}
        pkg_cur=${pkg_cur#*:}
        pkg_lat=${pkg_lat%%+*}
        pkg_lat=${pkg_lat#*:}
        _updates_print_row "$pkg" "${pkg_cur:0:15}" "${pkg_lat:0:15}"
    done
    if command -v timedatectl >/dev/null 2>&1; then
        printf '\n'
        if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || :) == yes ]]; then
            info 'Синхронизация времени NTP · активна.'
        else
            warn 'Синхронизация времени NTP · не подтверждена.'
        fi
    fi
}
