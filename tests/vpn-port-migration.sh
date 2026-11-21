#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/security.sh
source "$project/lib/security.sh"
# shellcheck source=lib/vpn-port.sh
source "$project/lib/vpn-port.sh"

CONFIG_DIR=$(mktemp -d)
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
VPN_PORTS='9443/tcp 2443/udp'
DETECTED_PORTS=9443/tcp
ENABLE_SECURITY=yes
ENABLE_SELFSTEAL=yes
SSH_PORT=22
NODE_PORT=3003
declare -A FIREWALL_RULES=([9443]=allow)
refreshes=0

require_config() { :; }
security_ufw_active() { :; }
security_preflight() { :; }
security_ufw_set_boot() { [[ $1 == enabled ]]; }
security_detect_vpn_ports() { printf '%s\n' "$DETECTED_PORTS"; }
security_allow_vpn_ports() { FIREWALL_RULES["${1%/*}"]=allow; }
vpn_port_is_listening() { [[ " $DETECTED_PORTS " == *" $1/tcp "* ]]; }
vpn_port_owned_rules() { if [[ "${FIREWALL_RULES[$1]-}" == deny && $2 == vpn-closed ]]; then printf '1\n'; fi; }
vpn_port_delete_owned() {
    if [[ "${FIREWALL_RULES[$1]-}:$2" == allow:vpn || "${FIREWALL_RULES[$1]-}:$2" == deny:vpn-closed ]]; then unset 'FIREWALL_RULES[$1]'; fi
}
vpn_port_block() { FIREWALL_RULES[$1]=deny; }
save_config() { printf '%s\n' "$VPN_PORTS" > "$CONFIG_DIR/ports"; }
selfsteal_public_port() { printf '%s\n' "${VPN_PORTS%%/*}"; }
selfsteal_refresh_redirect() { refreshes=$((refreshes + 1)); }
selfsteal_verify() { :; }
run_change() { shift; "$@"; }
ufw() {
    local port
    [[ $* == status ]] || return 1
    printf 'Status: active\n'
    for port in "${!FIREWALL_RULES[@]}"; do
        printf '%s/tcp %s Anywhere\n' "$port" "${FIREWALL_RULES[$port]^^}"
    done
}

if vpn_port_prepare 9443 22 >/dev/null 2>&1; then exit 1; fi
if vpn_port_prepare 9443 3003 >/dev/null 2>&1; then exit 1; fi
vpn_port_prepare 9443 443
[[ $(vpn_port_read) == $'9443\t443\tno\tno' ]]
[[ $VPN_PORTS == '9443/tcp 2443/udp 443/tcp' ]]
[[ ${FIREWALL_RULES[9443]} == allow && ${FIREWALL_RULES[443]} == allow && $refreshes == 0 ]]
if vpn_port_finish close >/dev/null 2>&1; then exit 1; fi
DETECTED_PORTS='9443/tcp 443/tcp'
if vpn_port_finish close >/dev/null 2>&1; then exit 1; fi
vpn_port_finish keep
[[ $VPN_PORTS == '443/tcp 2443/udp 9443/tcp' && $refreshes == 1 ]]
[[ ${FIREWALL_RULES[9443]} == allow && ! -e $CONFIG_DIR/vpn-port.json ]]
DETECTED_PORTS=443/tcp
vpn_port_close 9443
[[ $VPN_PORTS == '443/tcp 2443/udp' && ${FIREWALL_RULES[9443]} == deny ]]
vpn_port_prepare 443 9443
[[ $(vpn_port_read) == $'443\t9443\tno\tyes' ]]
[[ ${FIREWALL_RULES[9443]} == allow ]]
vpn_port_cancel
[[ ${FIREWALL_RULES[9443]} == deny && ! -e $CONFIG_DIR/vpn-port.json ]]
vpn_port_prepare 443 10443
DETECTED_PORTS=10443/tcp
vpn_port_finish close
[[ ${FIREWALL_RULES[443]} == deny && ${FIREWALL_RULES[10443]} == allow && $VPN_PORTS == '10443/tcp 2443/udp' ]]

profile='{"inbounds":[{"port":9443,"tag":"vpn"},{"port":2443,"tag":"other"}]}'
vpn_port_profile 9443 443 <<< "$profile" | jq -e '[.inbounds[].port] == [443,2443]' >/dev/null
if vpn_port_profile 9443 2443 <<< "$profile" >/dev/null 2>&1; then exit 1; fi
printf 'Проверены перенос VPN, сохранение и закрытие старого порта, отмена и обновление JSON.\n'
