#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$PROJECT_DIR/lib/ui.sh"
# shellcheck source=lib/security.sh
source "$PROJECT_DIR/lib/security.sh"
# shellcheck source=lib/standalone.sh
source "$PROJECT_DIR/lib/standalone.sh"

CONFIG_DIR=$(mktemp -d)
trap 'rm -rf -- "$CONFIG_DIR"' EXIT
UI_INTERACTIVE=no
UFW_MODE=inactive
SKIP_APPLY=no

apt_install_missing() { :; }
prepare_security() { :; }
get_admin_ip() { ADMIN_IP=192.0.2.7; }
detect_ssh_port() { printf '2202\n'; }
wizard_input() { printf 'node.example.com\n'; }
select_selfsteal_server() { printf '%s\n' "${2:-$1}"; }
selfsteal_preflight() { :; }
selfsteal_apply() { :; }
bbr_apply() { :; }
traffic_guard_apply() { :; }
security_install_sshd_jail() { :; }

sysctl() {
    case "$2" in
        net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
        net.core.default_qdisc) printf 'fq\n' ;;
    esac
}

ufw() {
    printf '%s\n' "$*" >> "$CONFIG_DIR/ufw.log"
    case "$1" in
        status)
            if [[ $UFW_MODE == inactive ]]; then
                printf 'Status: inactive\n'
            else
                printf 'Status: active\n'
                if [[ ${2-} == numbered && $UFW_MODE == managed ]]; then
                    printf '[ 1] 2202/tcp ALLOW IN Anywhere # remna-node-setup:ssh\n'
                fi
            fi
            ;;
        --force)
            if [[ ${2-} == enable ]]; then UFW_MODE=managed; fi
            ;;
    esac
}

run_change() {
    local scope=$1
    shift
    printf '%s\n' "$scope" > "$CONFIG_DIR/scope"
    [[ $SKIP_APPLY == no ]] || return 1
    "$@"
}

if load_host_settings; then exit 1; fi
standalone_bbr
load_host_settings
[[ $ENABLE_BBR == yes && -z $SSH_PORT && -z $NODE_PORT && -z $PANEL_IPS ]]
[[ $(< "$CONFIG_DIR/scope") == 'config bbr' ]]

standalone_security
load_host_settings
[[ $SSH_PORT == 2202 && $ADMIN_IPS == 192.0.2.7 && $ENABLE_BBR == yes ]]
[[ $(< "$CONFIG_DIR/scope") == 'config network' ]]
grep -Fqx 'prepend allow in proto tcp to any port 2202 comment remna-node-setup:ssh' "$CONFIG_DIR/ufw.log"
if grep -Eq '(port (80|443) |remna-node-setup:(panel|node|vpn))' "$CONFIG_DIR/ufw.log"; then exit 1; fi

: > "$CONFIG_DIR/ufw.log"
standalone_selfsteal nginx
load_host_settings
[[ $NODE_DOMAIN == node.example.com && $SELFSTEAL_SERVER == nginx && $ENABLE_SELFSTEAL == yes ]]
[[ $(< "$CONFIG_DIR/scope") == 'config selfsteal network' ]]
grep -Fqx 'prepend allow in proto tcp to any port 80 comment remna-node-setup:acme' "$CONFIG_DIR/ufw.log"
if grep -Eq '(default |port (443|2202) |remna-node-setup:(panel|node|vpn|ssh))' "$CONFIG_DIR/ufw.log"; then exit 1; fi

UFW_MODE=foreign
: > "$CONFIG_DIR/ufw.log"
standalone_selfsteal caddy
load_host_settings
[[ $SELFSTEAL_SERVER == caddy && $(< "$CONFIG_DIR/scope") == 'config selfsteal' ]]
if grep -q '^prepend ' "$CONFIG_DIR/ufw.log"; then exit 1; fi

UFW_MODE=inactive
if standalone_traffic_guard; then exit 1; fi
UFW_MODE=managed
standalone_traffic_guard <<< y
load_host_settings
[[ $ENABLE_TRAFFIC_GUARD == yes && $ENABLE_SELFSTEAL == yes && $ENABLE_BBR == yes ]]
[[ $(< "$CONFIG_DIR/scope") == 'config network' ]]

cp -- "$CONFIG_DIR/host.json" "$CONFIG_DIR/before.json"
SKIP_APPLY=yes
if standalone_selfsteal nginx; then exit 1; fi
cmp -s "$CONFIG_DIR/before.json" "$CONFIG_DIR/host.json"

printf '%s\n' 'Standalone-компоненты, настройки и области отката проверены.'
