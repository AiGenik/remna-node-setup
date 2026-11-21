#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/manager.sh
source "$PROJECT_DIR/lib/manager.sh"
# shellcheck source=lib/selfsteal.sh
source "$PROJECT_DIR/lib/selfsteal.sh"
# shellcheck source=lib/selfsteal-nginx.sh
source "$PROJECT_DIR/lib/selfsteal-nginx.sh"
# shellcheck source=lib/traffic-guard.sh
source "$PROJECT_DIR/lib/traffic-guard.sh"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture/state"
BACKUP_DIR="$fixture/backups"
mkdir -p -- "$STATE_DIR/traffic-guard" "$BACKUP_DIR"
printf '0.0.5\n' > "$STATE_DIR/traffic-guard/version"

SELFSTEAL_SERVER=nginx
NODE_DOMAIN=node.example.com
NODE_PORT=
VPN_PORTS=
ENABLE_SECURITY=no
ENABLE_BBR=no
ENABLE_TRAFFIC_GUARD=no
ENABLE_SELFSTEAL=yes
owned=no timer=no guard=no dns=yes

_selfsteal_caddy_owned_config() { return 1; }
_selfsteal_nginx_owned_config() { [[ $owned == yes ]]; }
selfsteal_verify() { return 0; }
systemctl() { [[ $timer == yes ]]; }
traffic_guard_firewall_active() { [[ $guard == yes ]]; }
load_config() { return 0; }
_selfsteal_validate_domain() { [[ $1 == report && $dns == yes ]]; }
bbr_status() { :; }
security_os_updates_status() { :; }

if selfsteal_status >/dev/null 2>&1; then exit 1; fi
owned=yes
if selfsteal_status >/dev/null 2>&1; then exit 1; fi
timer=yes
if traffic_guard_status required >/dev/null 2>&1; then exit 1; fi
guard=yes
traffic_guard_status required >/dev/null

doctor >/dev/null
dns=no
if doctor >/dev/null; then exit 1; fi
[[ $(backup_scope) == 'config selfsteal' ]]
ENABLE_TRAFFIC_GUARD=yes
[[ $(backup_scope) == 'config network selfsteal' ]]
printf '%s\n' 'Проверены диагностика DNS, Certbot, TrafficGuard и состав снимка.'
