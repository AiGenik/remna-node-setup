#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/security.sh
source "$PROJECT_DIR/lib/security.sh"

log=$(mktemp)
STATE_DIR=$(mktemp -d)
trap 'rm -rf -- "$log" "$STATE_DIR"' EXIT

SSH_PORT=2202
NODE_PORT=3003
PANEL_IPS='192.0.2.3 2001:db8::3'
ENABLE_SELFSTEAL=yes
VPN_PORTS_SAVED=no
MOCK_UFW_STATE=active
MOCK_UFW_DEFAULT=deny
MOCK_UFW_NUMBERED=
MOCK_UFW_STORED=
MOCK_UFW_EFFECTIVE=
MOCK_UPDATES_STATE=1
MOCK_APT_UPGRADE_TIMER=yes
MOCK_TRAFFIC_GUARD=no
MOCK_UFW_BOOT=enabled

ss() {
    cat <<'SOCKETS'
tcp LISTEN 0 64 *:9443 *:* users:(("rw-core",pid=100,fd=3))
udp UNCONN 0 0 [::]:2443 [::]:* users:(("xray",pid=101,fd=7))
udp UNCONN 0 0 [::1]:2444 [::]:* users:(("xray",pid=101,fd=8))
tcp LISTEN 0 1 127.8.0.1:8443 0.0.0.0:* users:(("rw-core",pid=100,fd=5))
tcp LISTEN 0 1 [::ffff:127.0.0.2]:8444 [::]:* users:(("rw-core",pid=100,fd=6))
tcp LISTEN 0 1 [fe80::1]%eth0:8100 [::]:* users:(("xray",pid=101,fd=9))
tcp LISTEN 0 64 *:3003 *:* users:(("rw-node",pid=99,fd=6))
tcp LISTEN 0 64 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=98,fd=3))
tcp LISTEN 0 64 192.0.2.4:9444 0.0.0.0:* users:(("rw-core",pid=100,fd=8))
tcp LISTEN 0 64 192.0.2.5:9444 0.0.0.0:* users:(("nginx",pid=98,fd=4))
tcp LISTEN 0 64 *:10443 *:* users:(("xray-other",pid=103,fd=7))
udp UNCONN 0 0 *:45123 *:* users:(("rw-core",pid=100,fd=9))
udp UNCONN 0 0 [::]:58901 [::]:* users:(("xray",pid=101,fd=10))
SOCKETS
}

wizard_input() { "$3" "$2"; }
security_install_sshd_jail() { :; }
ufw() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
        'status')
            printf '%s\n' "Status: $MOCK_UFW_STATE" "$MOCK_UFW_EFFECTIVE"
            ;;
        'status numbered')
            printf '%s\n' "Status: $MOCK_UFW_STATE" "$MOCK_UFW_NUMBERED"
            ;;
        'status verbose')
            printf '%s\n' "Status: $MOCK_UFW_STATE" "Default: $MOCK_UFW_DEFAULT (incoming), allow (outgoing), deny (routed)"
            ;;
        'show added')
            printf '%s\n' "$MOCK_UFW_STORED"
            ;;
        '--force enable') MOCK_UFW_STATE=active ;;
        'default deny incoming')
            MOCK_UFW_DEFAULT=deny
            MOCK_TRAFFIC_GUARD=no
            ;;
    esac
}

traffic_guard_firewall_active() { [[ $MOCK_TRAFFIC_GUARD == yes ]]; }
systemctl() {
    printf '%s\n' "$*" >> "$log"
    case "$*" in
        'is-enabled ufw.service') printf '%s\n' "$MOCK_UFW_BOOT" ;;
        'unmask ufw.service') MOCK_UFW_BOOT=disabled ;;
        'enable ufw.service') MOCK_UFW_BOOT=enabled ;;
        'disable ufw.service') MOCK_UFW_BOOT=disabled ;;
        'mask ufw.service') MOCK_UFW_BOOT=masked ;;
        'restart antiscan-move-rules.service') MOCK_TRAFFIC_GUARD=yes ;;
        *) return 1 ;;
    esac
}

unattended-upgrade() { return 1; }
apt-config() {
    printf '%s\n' "APT::Periodic::Enable \"$MOCK_UPDATES_STATE\";" \
        'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "always";'
}
active() {
    if [[ $1 == apt-daily-upgrade.timer ]]; then printf '%s\n' "$MOCK_APT_UPGRADE_TIMER"; else printf 'yes\n'; fi
}

unset VPN_PORTS
[[ $(security_configured_vpn_ports) == '443/tcp' ]]
VPN_PORTS=
[[ -z $(security_configured_vpn_ports) ]]
[[ $(security_normalize_vpn_ports '9443, 2443/UDP, 9443/tcp') == '9443/tcp 2443/udp' ]]
[[ -z $(security_normalize_vpn_ports 'нет') ]]
for invalid in 65536 0 3003/tcp 2202 8443/tcp 80/tcp 9443/sctp '9443/tcp *'; do
    if security_normalize_vpn_ports "$invalid" >/dev/null 2>&1; then exit 1; fi
done
[[ $(security_detect_vpn_ports) == '2443/udp 9443/tcp' ]]
VPN_PORTS='9443/tcp 45123/udp'
[[ $(security_detect_vpn_ports) == '2443/udp 9443/tcp 45123/udp' ]]
unset VPN_PORTS
[[ $(security_prompt_vpn_ports '443/tcp' 2>/dev/null) == '2443/udp 9443/tcp' ]]
VPN_PORTS_SAVED=yes
[[ $(security_prompt_vpn_ports '443/tcp' 2>/dev/null) == '443/tcp' ]]
[[ $(security_prompt_vpn_ports '65000/tcp' 2>/dev/null) == '65000/tcp' ]]

VPN_PORTS='9443/tcp 2443/udp 9444/tcp'
MOCK_UFW_NUMBERED=$'[ 2] 443/tcp ALLOW IN Anywhere # remna-node-setup:vpn\n[ 3] 9444/tcp ALLOW IN Anywhere # manual\n[ 5] 443/tcp (v6) ALLOW IN Anywhere (v6) # remna-node-setup:vpn'
MOCK_UFW_STORED=$'ufw allow 9444/tcp comment \'manual\'\nufw deny 9445/tcp comment \'manual\'\nufw allow from 198.51.100.8 to any port 2202 proto tcp'
security_apply
if security_allow_vpn_ports '9445/tcp' > /dev/null 2>&1; then exit 1; fi
grep -Fqx -- '--force delete 5' "$log"
grep -Fqx -- '--force delete 2' "$log"
grep -Fqx 'prepend deny in proto tcp to any port 3003 comment remna-node-setup:node' "$log"
grep -Fqx 'prepend allow in proto tcp from 192.0.2.3 to any port 3003 comment remna-node-setup:panel' "$log"
grep -Fqx 'prepend allow in proto tcp from 2001:db8::3 to any port 3003 comment remna-node-setup:panel' "$log"
grep -Fqx 'prepend allow in proto tcp to any port 80 comment remna-node-setup:acme' "$log"
grep -Fqx 'allow in proto tcp to any port 9443 comment remna-node-setup:vpn' "$log"
grep -Fqx 'allow in proto udp to any port 2443 comment remna-node-setup:vpn' "$log"
if grep -Eq -- 'delete 3|port (443|2202|8443|9444|9445) |--force enable|default deny' "$log"; then exit 1; fi

mkdir -p "$STATE_DIR/traffic-guard"
printf '0.0.5\n' > "$STATE_DIR/traffic-guard/version"
MOCK_UFW_DEFAULT=allow
MOCK_TRAFFIC_GUARD=yes
: > "$log"
security_check_guard_addresses() { :; }
if security_apply; then exit 1; fi
if grep -Fqx 'default deny incoming' "$log"; then exit 1; fi
MOCK_UFW_STORED=
: > "$log"
security_apply
grep -Fqx 'default deny incoming' "$log"
grep -Fqx 'restart antiscan-move-rules.service' "$log"
[[ $MOCK_TRAFFIC_GUARD == yes ]]

MOCK_UFW_EFFECTIVE=$'9443/tcp ALLOW Anywhere\n2443/udp ALLOW IN Anywhere'
security_vpn_status
MOCK_UFW_EFFECTIVE=$'9443/tcp (v6) ALLOW Anywhere (v6)\n2443/udp ALLOW IN Anywhere'
if security_vpn_status > "$log" 2>&1; then exit 1; fi
MOCK_UFW_EFFECTIVE=$'9443/tcp DENY IN Anywhere\n9443/tcp ALLOW IN Anywhere\n2443/udp ALLOW IN Anywhere'
if security_vpn_status > "$log" 2>&1; then exit 1; fi
MOCK_UFW_EFFECTIVE=$'9443/tcp ALLOW OUT Anywhere\n2443/udp ALLOW IN Anywhere'
if security_vpn_status > "$log" 2>&1; then exit 1; fi
grep -Fq 'Для 9443/tcp не найдено' "$log"
MOCK_UFW_BOOT=masked
if security_ufw_boot_verified >/dev/null 2>&1; then exit 1; fi
security_ufw_set_boot enabled
[[ $MOCK_UFW_BOOT == enabled ]]
security_ufw_set_boot masked
[[ $MOCK_UFW_BOOT == masked ]]
MOCK_UFW_BOOT=enabled

MOCK_UFW_STATE=inactive
MOCK_UFW_STORED=$'ufw allow 443/tcp comment \'remna-node-setup:vpn\'\nufw deny 8444/tcp comment \'remna-node-setup:vpn-closed\'\nufw allow from 2001:db8::3 to any port 3003 proto tcp comment \'remna-node-setup:panel\'\nufw allow 8443/tcp comment \'manual\''
: > "$log"
security_remove_managed_ufw_rules
grep -Fqx -- '--force delete allow 443/tcp comment remna-node-setup:vpn' "$log"
grep -Fqx -- '--force delete deny 8444/tcp comment remna-node-setup:vpn-closed' "$log"
grep -Fqx -- '--force delete allow from 2001:db8::3 to any port 3003 proto tcp comment remna-node-setup:panel' "$log"
if grep -Fq 'delete allow 8443/tcp' "$log"; then exit 1; fi

[[ $(security_os_updates_status) == 'Автоматические обновления Ubuntu настроены.' ]]
MOCK_UPDATES_STATE=0
[[ $(security_os_updates_status 2>&1) == *'не подтверждены'* ]]
MOCK_UPDATES_STATE=1
MOCK_APT_UPGRADE_TIMER=no
[[ $(security_os_updates_status 2>&1) == *'не подтверждены'* ]]

printf '%s\n' 'Обнаружение VPN-портов, изоляция служебных портов и правила UFW проверены.'
