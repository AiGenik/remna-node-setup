#!/usr/bin/env bash

security_ufw_state() {
    local status
    status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
    case ${status%%$'\n'*} in
        'Status: active') printf 'active\n' ;;
        'Status: inactive') printf 'inactive\n' ;;
        *) return 1 ;;
    esac
}

security_ufw_active() {
    [[ $(security_ufw_state) == active ]]
}

security_ufw_boot_state() {
    local state
    state=$(systemctl is-enabled ufw.service 2>/dev/null) || :
    case $state in
        enabled|enabled-runtime|disabled|masked|masked-runtime) printf '%s\n' "$state" ;;
        *) return 1 ;;
    esac
}

security_ufw_set_boot() {
    local desired=$1 current
    case $desired in
        enabled|enabled-runtime|disabled|masked|masked-runtime) ;;
        *) return 1 ;;
    esac
    current=$(security_ufw_boot_state) || { fail 'Не удалось определить автозапуск ufw.service.'; return 1; }
    if [[ $current == "$desired" ]]; then return 0; fi
    case $current in
        masked) systemctl unmask ufw.service || return ;;
        masked-runtime) systemctl --runtime unmask ufw.service || return ;;
        enabled-runtime) systemctl --runtime disable ufw.service || return ;;
        enabled) systemctl disable ufw.service || return ;;
    esac
    case $desired in
        enabled) systemctl enable ufw.service || return ;;
        enabled-runtime) systemctl --runtime enable ufw.service || return ;;
        masked) systemctl mask ufw.service || return ;;
        masked-runtime) systemctl --runtime mask ufw.service || return ;;
        disabled) ;;
    esac
    [[ $(security_ufw_boot_state) == "$desired" ]]
}

security_ufw_boot_verified() {
    local state
    state=$(security_ufw_boot_state) || state=неизвестен
    if [[ $state != enabled ]]; then
        warn "UFW не восстановит правила штатно после запуска · $state. Откройте «Восстановить автозапуск защиты»."
        return 1
    fi
}

security_repair_boot() {
    local unit
    security_ufw_set_boot enabled || return
    if [[ -s $STATE_DIR/traffic-guard/version ]]; then
        for unit in antiscan-ipset-restore.service antiscan-move-rules.service; do
            systemctl enable "$unit" || return
        done
        traffic_guard_firewall_active || { fail 'Действующие правила TrafficGuard не подтверждены.'; return 1; }
    fi
    if fail2ban-client status sshd >/dev/null 2>&1; then
        systemctl enable fail2ban.service || return
    fi
    info 'Автозапуск защиты восстановлен.'
}

security_ufw_public_rule() {
    local entry=$1 rules=$2 port protocol
    port=${entry%/*}
    protocol=${entry#*/}
    awk -v port="$port" -v proto="$protocol" '
        {
            target = $1
            if (target != port && target != port "/" proto) next
            if ($0 ~ /\(v6\)/) next
            if ($0 ~ /[[:space:]](DENY|REJECT)([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)/) {
                exit 1
            }
            if ($0 ~ /[[:space:]](ALLOW|LIMIT)([[:space:]]+IN)?[[:space:]]+Anywhere([[:space:]]|$)/) {
                found = 1
                exit 0
            }
        }
        END { exit (found ? 0 : 1) }
    ' <<< "$rules"
}

security_configured_vpn_ports() {
    if [[ ${VPN_PORTS+x} ]]; then
        printf '%s\n' "$VPN_PORTS"
    elif [[ -n ${NODE_PORT:-} ]]; then
        printf '443/tcp\n'
    fi
}

security_normalize_vpn_ports() {
    local input=${1,,} entry port protocol item normalized=
    local -a entries=()
    input=${input//,/ }
    input=${input//$'\n'/ }
    read -r -a entries <<< "$input"
    if (( ${#entries[@]} == 0 )) || [[ ${#entries[@]} == 1 && ${entries[0]} =~ ^(none|нет|-)$ ]]; then
        printf '\n'
        return 0
    fi
    for entry in "${entries[@]}"; do
        port=${entry%%/*}
        protocol=tcp
        if [[ $entry == */* ]]; then protocol=${entry#*/}; fi
        if ! valid_port "$port" || [[ $protocol != tcp && $protocol != udp ]]; then
            fail 'Укажите порты как 9443/tcp, 2443/udp или введите «нет».'
            return 1
        fi
        if [[ $protocol == tcp &&
              ( $port == "${SSH_PORT:-}" || $port == "${NODE_PORT:-}" ||
                ( ${ENABLE_SELFSTEAL:-no} == yes && ( $port == 80 || $port == 8443 ) ) ) ]]; then
            fail "Порт $port/tcp зарезервирован для SSH, панели или self-steal."
            return 1
        fi
        item=$port/$protocol
        if [[ " $normalized " != *" $item "* ]]; then normalized+=${normalized:+ }$item; fi
    done
    printf '%s\n' "$normalized"
}

security_detect_vpn_ports() {
    local configured
    configured=$(security_configured_vpn_ports 2>/dev/null) || configured=
    LC_ALL=C ss -H -lntup | python3 -c '
import ipaddress
import pathlib
import re
import sys

configured = set()
for item in sys.argv[1].split():
    if "/" in item:
        p, proto = item.split("/", 1)
        if p.isdecimal():
            configured.add((int(p), proto))

eph_low, eph_high = 32768, 60999
try:
    parts = pathlib.Path("/proc/sys/net/ipv4/ip_local_port_range").read_text().split()
    if len(parts) == 2 and parts[0].isdecimal() and parts[1].isdecimal():
        eph_low, eph_high = int(parts[0]), int(parts[1])
except OSError:
    pass

vpn_ports, other_ports = set(), set()
for line in sys.stdin:
    fields = line.split(maxsplit=6)
    if len(fields) < 6 or fields[0] not in ("tcp", "udp"):
        continue
    address, _, port = fields[4].rpartition(":")
    if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
        continue
    port_num = int(port)
    address = address.strip("[]").split("%", 1)[0]
    if address != "*":
        try:
            bound = ipaddress.ip_address(address)
        except ValueError:
            continue
        if bound.version == 6 and bound.ipv4_mapped is not None:
            bound = bound.ipv4_mapped
        if bound.is_loopback or bound.is_link_local or bound.is_multicast:
            continue
    owners = re.findall(r"\(\"([^\"]+)\",pid=\d+,", fields[6] if len(fields) == 7 else "")
    is_vpn = bool(owners and set(owners) <= {"rw-core", "xray"})
    # Ignore outbound ephemeral UDP sockets allocated by xray/rw-core (ss -lu lists all UNCONN sockets).
    if is_vpn and fields[0] == "udp" and eph_low <= port_num <= eph_high and (port_num, "udp") not in configured:
        continue
    ports = vpn_ports if is_vpn else other_ports
    ports.add((port_num, fields[0]))

print(" ".join(f"{port}/{protocol}" for port, protocol in sorted(vpn_ports - other_ports)))
' "$configured"
}

security_prompt_vpn_ports() {
    local saved=${1-} detected default
    detected=$(security_detect_vpn_ports 2>/dev/null) || detected=
    if [[ -n $detected && $detected != "$saved" ]]; then
        info "  Сейчас Xray слушает $detected." >&2
    fi
    if [[ $saved == '443/tcp' && -n $detected && $detected != "$saved" && ${VPN_PORTS_SAVED:-yes} == no ]]; then
        saved=
    fi
    default=${saved:-${detected:-нет}}
    info '  Config Profiles → inbounds → port · 9443/tcp 2443/udp' >&2
    info '  Другие порты добавьте через пробел. «нет» — пропустить.' >&2
    wizard_input 'Входящие порты VPN' "$default" security_normalize_vpn_ports
}

security_preflight() {
    local node_port=${NODE_PORT:-} vpn_ports
    valid_port "${SSH_PORT:-}" || { fail "Укажите действующий TCP-порт SSH."; return 1; }
    if [[ -n $node_port ]] && ! valid_port "$node_port"; then
        fail "Укажите служебный TCP-порт ноды из панели."
        return 1
    fi
    if [[ ( -n $node_port && $node_port == "$SSH_PORT" ) ||
          ( ${ENABLE_SELFSTEAL:-no} == yes &&
            ( $SSH_PORT == 80 || $SSH_PORT == 8443 || $node_port == 80 || $node_port == 8443 ) ) ]]; then
        fail "Служебный порт ноды или порт SSH конфликтует с портом проекта."
        return 1
    fi
    vpn_ports=$(security_configured_vpn_ports) || return 1
    security_normalize_vpn_ports "$vpn_ports" >/dev/null || return 1
    if ! python3 - "$node_port" "${PANEL_IPS:-}" "${ADMIN_IPS:-} ${ADMIN_IP:-}" <<'PY'
import ipaddress
import sys

try:
    node_port, panel, admins = sys.argv[1:]
    if node_port and not panel.split():
        raise ValueError
    for address in panel.split():
        ipaddress.ip_address(address)
    for address in admins.split():
        ipaddress.ip_network(address, strict=False)
except ValueError:
    sys.exit(1)
PY
    then
        if [[ -n $node_port ]]; then
            fail "Укажите IP-адрес панели и проверьте доверенные адреса SSH."
        else
            fail "Проверьте доверенные адреса SSH."
        fi
        return 1
    fi

    # Ubuntu 24.04 enables IPv6 filtering by default. Absence of the file is
    # expected during preflight before package installation.
    if [[ -f /etc/default/ufw ]] && ! grep -Eq '^IPV6=yes([[:space:]]|$)' /etc/default/ufw; then
        fail "В UFW отключена фильтрация IPv6. Проверьте IPV6=yes в /etc/default/ufw."
        return 1
    fi
}

security_remove_managed_ufw_rules() {
    local keep_ssh=${1:-no} rules number rule groups='ssh|panel|node|vpn|vpn-closed|acme'
    local -a arguments=()
    if [[ $keep_ssh == yes ]]; then groups='panel|node|vpn|vpn-closed|acme'; fi
    local stored_pattern="^ufw ((allow|deny) [0-9]+/(tcp|udp)|allow from [[:xdigit:].:/]+ to any port [0-9]+ proto tcp) comment '(remna-node-setup:($groups))'$"

    if ! security_ufw_active; then
        # Numbered rules are unavailable while UFW is disabled. Match only
        # rules written by this project and pass the comment on deletion.
        rules=$(LC_ALL=C ufw show added) || return 1
        while IFS= read -r rule; do
            if [[ $rule =~ $stored_pattern ]]; then
                read -r -a arguments <<< "${BASH_REMATCH[1]}"
                ufw --force delete "${arguments[@]}" comment "${BASH_REMATCH[4]}" || return 1
            fi
        done <<< "$rules"
        return 0
    fi

    rules=$(LC_ALL=C ufw status numbered) || return 1

    # UFW indexes one address family per entry. Delete from the bottom up.
    while IFS= read -r number; do
        [[ -n $number ]] || continue
        ufw --force delete "$number" || return 1
    done < <(
        sed -nE "s/^\\[ *([0-9]+)\\].*# remna-node-setup:($groups)([[:space:]]|$).*/\\1/p" <<< "$rules" |
            sort -rn
    )
}

security_external_ufw_rules() {
    local rules rule
    local managed_rule=" comment 'remna-node-setup:(ssh|panel|node|vpn|vpn-closed|acme)'$"
    rules=$(LC_ALL=C ufw show added) || return 1
    while IFS= read -r rule; do
        if [[ $rule == 'ufw '* && ! $rule =~ $managed_rule ]]; then
            printf 'yes\n'
            return 0
        fi
    done <<< "$rules"
    printf 'no\n'
}

security_check_guard_addresses() (
    local stage
    stage=$(mktemp -d "$STATE_DIR/.guard-addresses.XXXXXX") || return
    trap 'rm -rf -- "$stage"' EXIT
    ipset save SCANNERS-BLOCK-V4 > "$stage/v4" || return
    ipset save SCANNERS-BLOCK-V6 > "$stage/v6" || return
    awk '$1 == "add" {print $3}' "$stage/v4" "$stage/v6" > "$stage/networks" || return
    traffic_guard_validate_list "$stage/networks" "$stage/expected" >/dev/null
)

security_allow_vpn_ports() {
    local selected=$1 rules entry port protocol
    local -a entries=()
    [[ -n $selected ]] || return 0
    rules=$(LC_ALL=C ufw show added) || return 1
    read -r -a entries <<< "$selected"
    for entry in "${entries[@]}"; do
        port=${entry%/*}
        protocol=${entry#*/}
        # UFW's append can replace a matching rule's action or comment.
        # Preserve existing rules and report explicit public denials.
        if grep -Eq "^ufw (deny|reject) (log(-all)? )?$port(/$protocol)?( comment |$)" <<< "$rules"; then
            fail "UFW уже запрещает $entry отдельным правилом. Проверьте sudo ufw status numbered."
            return 1
        fi
        if grep -Eq "^ufw (allow|limit) (log(-all)? )?$port(/$protocol)?( comment |$)" <<< "$rules"; then
            continue
        fi
        ufw allow in proto "$protocol" to any port "$port" comment remna-node-setup:vpn || return 1
    done
}

security_install_sshd_jail() {
    local config=/etc/fail2ban/jail.d/remna-node-setup.local
    local temporary admin_ips attempt

    admin_ips=$(printf '%s\n' "${ADMIN_IPS:-}" "${ADMIN_IP:-}" | awk '{for (i = 1; i <= NF; i++) if (!seen[$i]++) printf " %s", $i}')
    temporary=$(mktemp /etc/fail2ban/jail.d/.remna-node-setup.XXXXXX) || return 1
    if ! cat > "$temporary" <<EOF_JAIL
[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
banaction = iptables-multiport[blocktype=DROP]
ignoreip = 127.0.0.1/8 ::1$admin_ips
findtime = 10m
bantime = 1h
maxretry = 5
EOF_JAIL
    then
        rm -f -- "$temporary"
        return 1
    fi
    if ! chmod 0644 "$temporary" || ! mv -f -- "$temporary" "$config"; then
        rm -f -- "$temporary"
        return 1
    fi

    fail2ban-client -t || return 1
    systemctl enable --now fail2ban.service || return 1
    for (( attempt = 1; attempt <= 10; attempt++ )); do
        if fail2ban-client ping >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    fail2ban-client reload sshd || return 1
    fail2ban-client status sshd >/dev/null
}

security_apply() {
    local panel_ip vpn_ports ufw_state ufw_status external_rules change_default=yes guard_was_active=no
    local -a panel_addresses=()
    security_preflight || return 1

    vpn_ports=$(security_configured_vpn_ports) || return 1
    vpn_ports=$(security_normalize_vpn_ports "$vpn_ports") || return 1
    ufw_state=$(security_ufw_state) || { fail 'Не удалось надёжно определить состояние UFW.'; return 1; }
    external_rules=$(security_external_ufw_rules) || return
    if [[ $ufw_state == active ]]; then
        ufw_status=$(LC_ALL=C ufw status verbose) || return 1
        if grep -Fq 'Default: deny (incoming),' <<< "$ufw_status"; then change_default=no; fi
        if [[ -n ${STATE_DIR:-} && -s $STATE_DIR/traffic-guard/version ]] &&
           traffic_guard_firewall_active; then
            guard_was_active=yes
            security_check_guard_addresses ||
                { fail 'Действующий TrafficGuard несовместим с выбранными доверенными адресами.'; return 1; }
        fi
    fi
    if [[ $external_rules == yes ]]; then
        if [[ $ufw_state != active || $change_default == yes ]]; then
            fail 'Найдены правила администратора. Перед запуском настройте действующий UFW и проверьте SSH с политикой deny incoming.'
            return 1
        fi
        info 'Существующая политика SSH сохранена.'
    fi
    security_remove_managed_ufw_rules "$external_rules" || return 1
    if [[ $external_rules == no ]]; then
        ufw allow in proto tcp to any port "$SSH_PORT" comment remna-node-setup:ssh || return 1
    fi
    # A full UFW reload can clear runtime hooks, including TrafficGuard's.
    if [[ $change_default == yes ]]; then ufw default deny incoming || return 1; fi
    if [[ -n ${NODE_PORT:-} ]]; then
        ufw prepend deny in proto tcp to any port "$NODE_PORT" comment remna-node-setup:node || return 1
        read -r -a panel_addresses <<< "$PANEL_IPS"
        for panel_ip in "${panel_addresses[@]}"; do
            ufw prepend allow in proto tcp from "$panel_ip" to any port "$NODE_PORT" comment remna-node-setup:panel || return 1
        done
    fi
    security_allow_vpn_ports "$vpn_ports" || return 1
    if [[ ${ENABLE_SELFSTEAL:-no} == yes ]]; then
        security_allow_acme || return 1
    fi

    if [[ $ufw_state == inactive ]]; then ufw --force enable || return 1; fi
    security_ufw_active || { fail "UFW не активировался."; return 1; }
    security_ufw_set_boot enabled || return
    if [[ $guard_was_active == yes ]] &&
       { [[ $change_default == yes ]] || ! traffic_guard_firewall_active; }; then
        if ! systemctl restart antiscan-move-rules.service || ! traffic_guard_firewall_active; then
            fail 'После применения правил не удалось подтвердить фильтр TrafficGuard.'
            return 1
        fi
    fi
    security_install_sshd_jail || return 1
    info "UFW включён. Fail2Ban защищает SSH на порту $SSH_PORT."
}

security_restore_traffic_guard() {
    if [[ $1 == yes ]] && ! traffic_guard_firewall_active; then
        if ! systemctl restart antiscan-move-rules.service || ! traffic_guard_firewall_active; then
            fail 'После обновления не удалось восстановить фильтр TrafficGuard.'
            return 1
        fi
    fi
}

security_apply_current() {
    local guard_was_active=no
    if [[ -s $STATE_DIR/traffic-guard/version ]] && traffic_guard_firewall_active; then
        guard_was_active=yes
    fi
    apt_install_current ufw fail2ban python3-systemd ipset iptables &&
        security_apply && security_restore_traffic_guard "$guard_was_active"
}

security_vpn_status() {
    local detected configured rules result=0 entry
    local -a entries=()
    configured=$(security_configured_vpn_ports) || return 1
    detected=$(security_detect_vpn_ports) || return 1
    info "Порты VPN в настройках — ${configured:-нет}."
    if [[ -z $detected ]]; then
        warn 'Xray ещё не слушает VPN-порты. Проверьте профиль ноды в Remnawave.'
        return 1
    fi
    info "Xray слушает — $detected."
    if security_ufw_active; then
        rules=$(LC_ALL=C ufw status) || return 1
        read -r -a entries <<< "$detected"
        for entry in "${entries[@]}"; do
            if ! security_ufw_public_rule "$entry" "$rules"; then
                warn "Для $entry не найдено отдельное публичное разрешение UFW. Проверьте «Порты и защита»."
                result=1
            fi
        done
    fi
    return "$result"
}

security_allow_acme() {
    ufw prepend allow in proto tcp to any port 80 comment remna-node-setup:acme
}

security_ufw_managed() {
    local rules
    security_ufw_active || return 1
    rules=$(LC_ALL=C ufw status numbered) || return 1
    grep -Eq '# remna-node-setup:ssh([[:space:]]|$)' <<< "$rules"
}

security_status() {
    if security_ufw_active; then
        info "UFW включён"
        security_ufw_boot_verified || :
    else
        warn "UFW выключен или недоступен"
    fi
    if command -v fail2ban-client >/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
        info 'Fail2Ban защищает SSH'
    else
        warn "Fail2Ban для SSH недоступен"
    fi
}

security_os_updates_status() {
    local options
    if command -v unattended-upgrade >/dev/null &&
       options=$(apt-config dump 2>/dev/null) &&
       awk '
           function scheduled(value) { return value == "\"always\";" || value ~ /^"[0-9]*[1-9][0-9]*";$/ }
           $1 == "APT::Periodic::Enable" { disabled = ($2 ~ /^"(0+|false|no)";$/) }
           $1 == "APT::Periodic::Update-Package-Lists" { refresh = scheduled($2) }
           $1 == "APT::Periodic::Unattended-Upgrade" { upgrade = scheduled($2) }
           END { exit (disabled || !refresh || !upgrade) }
       ' <<< "$options" &&
       [[ $(active apt-daily.timer) == yes && $(active apt-daily-upgrade.timer) == yes ]]; then
        info 'Автоматические обновления Ubuntu настроены.'
    else
        warn 'Автоматические обновления Ubuntu не подтверждены. Проверьте unattended-upgrades.'
    fi
    return 0
}

bbr_apply() {
    local config=/etc/sysctl.d/90-remna-node-setup-bbr.conf
    local available temporary

    if ! sysctl -n net.core.default_qdisc >/dev/null 2>&1; then
        warn "Ядро не позволяет задать очередь по умолчанию. Пропускаю настройку BBR и fq."
        return 0
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return 1
    if [[ " $available " != *' bbr '* ]]; then
        if ! modprobe tcp_bbr; then
            warn "Ядро не поддерживает BBR. Пропускаю настройку."
            return 0
        fi
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return 1
        if [[ " $available " != *' bbr '* ]]; then
            warn "BBR недоступен. Пропускаю настройку."
            return 0
        fi
    fi

    temporary=$(mktemp /etc/sysctl.d/.remna-node-setup.XXXXXX) || return 1
    if ! printf '%s\n' 'net.core.default_qdisc = fq' 'net.ipv4.tcp_congestion_control = bbr' > "$temporary" ||
       ! chmod 0644 "$temporary" || ! mv -f -- "$temporary" "$config"; then
        rm -f -- "$temporary"
        return 1
    fi
    sysctl -p "$config" >/dev/null || return 1
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != bbr || $(sysctl -n net.core.default_qdisc) != fq ]]; then
        fail "Не удалось подтвердить настройки BBR и fq."
        return 1
    fi
    info "BBR активен, fq задан как очередь по умолчанию."
}

bbr_status() {
    local congestion qdisc device current
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || congestion='недоступно'
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc='недоступно'
    info "Алгоритм TCP — $congestion, очередь по умолчанию — $qdisc"
    device=$(ip -o -4 route show default 2>/dev/null | awk 'NR == 1 {for (i=1; i<NF; i++) if ($i == "dev") print $(i+1)}') || return 0
    [[ -n $device ]] || return 0
    current=$(tc qdisc show dev "$device" 2>/dev/null | awk '$4 == "root" {print $2}') || return 0
    if [[ -n $current ]]; then info "Текущая очередь $device — $current"; fi
}

ipv6_apply() {
    local desired=${1:-${DISABLE_IPV6:-no}} config=/etc/sysctl.d/91-remna-node-setup-ipv6.conf temporary
    case $desired in
        yes|no) ;;
        *) fail 'Укажите yes или no для состояния IPv6.'; return 1 ;;
    esac
    if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        warn 'Ядро не поддерживает sysctl для IPv6. Пропускаю настройку.'
        return 0
    fi
    if [[ $desired == yes ]]; then
        temporary=$(mktemp /etc/sysctl.d/.remna-node-setup-ipv6.XXXXXX) || return 1
        if ! printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' > "$temporary" ||
           ! chmod 0644 "$temporary" || ! mv -f -- "$temporary" "$config"; then
            rm -f -- "$temporary"
            return 1
        fi
        sysctl -p "$config" >/dev/null || return 1
        if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) != 1 ||
              $(sysctl -n net.ipv6.conf.default.disable_ipv6) != 1 ]]; then
            fail 'Не удалось подтвердить отключение IPv6.'
            return 1
        fi
        info 'IPv6 отключён на интерфейсах VPS.'
    else
        rm -f -- "$config" || return 1
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null || return 1
        if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) != 0 ]]; then
            fail 'Не удалось включить IPv6.'
            return 1
        fi
        info 'IPv6 включён.'
    fi
    if declare -F selfsteal_refresh_redirect >/dev/null &&
       declare -F _selfsteal_nginx_owned_config >/dev/null &&
       _selfsteal_nginx_owned_config; then
        selfsteal_refresh_redirect || return 1
    fi
}

ipv6_status() {
    local flag
    if [[ ! -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        info 'IPv6 · недоступен в ядре'
        return 0
    fi
    flag=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) || flag=неизвестно
    case $flag in
        1) info 'IPv6 · отключён (sysctl)' ;;
        0) info 'IPv6 · включён' ;;
        *) info "IPv6 · $flag" ;;
    esac
}
