#!/usr/bin/env bash

security_ufw_active() {
    local status
    status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
    [[ ${status%%$'\n'*} == 'Status: active' ]]
}

security_preflight() {
    valid_port "${SSH_PORT:-}" || { fail "Укажите действующий TCP-порт SSH."; return 1; }
    valid_port "${NODE_PORT:-}" || { fail "Укажите служебный TCP-порт ноды из панели."; return 1; }
    if [[ $NODE_PORT == "$SSH_PORT" || $NODE_PORT == 80 || $NODE_PORT == 443 ||
          $NODE_PORT == 8443 || $SSH_PORT == 443 || $SSH_PORT == 8443 ||
          ( $SSH_PORT == 80 && ${ENABLE_SELFSTEAL:-no} == yes ) ]]; then
        fail "Служебный порт ноды или порт SSH конфликтует с портом проекта."
        return 1
    fi
    if ! python3 - "${PANEL_IPS:-}" "${ADMIN_IPS:-} ${ADMIN_IP:-}" <<'PY'
import ipaddress
import sys

try:
    panel = sys.argv[1].split()
    if not panel:
        raise ValueError
    for address in panel:
        ipaddress.ip_address(address)
    for address in sys.argv[2].split():
        ipaddress.ip_network(address, strict=False)
except ValueError:
    sys.exit(1)
PY
    then
        fail "Укажите IP-адрес панели и проверьте доверенные адреса SSH."
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
    local rules number
    rules=$(LC_ALL=C ufw status numbered) || return 1

    # UFW indexes one address family per entry. Delete from the bottom up.
    while IFS= read -r number; do
        [[ -n $number ]] || continue
        ufw --force delete "$number" || return 1
    done < <(
        sed -nE 's/^\[ *([0-9]+)\].*# remna-node-setup:(ssh|panel|node|vpn|acme)([[:space:]]|$).*/\1/p' <<< "$rules" |
            sort -rn
    )
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
banaction = iptables-multiport
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
    local panel_ip
    local -a panel_addresses=()
    security_preflight || return 1

    if security_ufw_active; then
        security_remove_managed_ufw_rules || return 1
    fi
    ufw prepend allow in proto tcp to any port "$SSH_PORT" comment remna-node-setup:ssh || return 1
    ufw default deny incoming || return 1
    ufw prepend deny in proto tcp to any port "$NODE_PORT" comment remna-node-setup:node || return 1
    read -r -a panel_addresses <<< "$PANEL_IPS"
    for panel_ip in "${panel_addresses[@]}"; do
        ufw prepend allow in proto tcp from "$panel_ip" to any port "$NODE_PORT" comment remna-node-setup:panel || return 1
    done
    ufw prepend allow in proto tcp to any port 443 comment remna-node-setup:vpn || return 1
    if [[ ${ENABLE_SELFSTEAL:-no} == yes ]]; then
        ufw prepend allow in proto tcp to any port 80 comment remna-node-setup:acme || return 1
    fi

    ufw --force enable || return 1
    security_ufw_active || { fail "UFW не активировался."; return 1; }
    security_install_sshd_jail || return 1
    info "UFW включён. Fail2Ban защищает SSH на порту $SSH_PORT."
}

security_status() {
    if security_ufw_active; then
        info "UFW включён"
    else
        warn "UFW выключен или недоступен"
    fi
    if command -v fail2ban-client >/dev/null && fail2ban-client status sshd 2>/dev/null; then
        :
    else
        warn "Fail2Ban для SSH недоступен"
    fi
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
    local congestion qdisc
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || congestion='недоступно'
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc='недоступно'
    info "Алгоритм TCP — $congestion, очередь по умолчанию — $qdisc"
}
