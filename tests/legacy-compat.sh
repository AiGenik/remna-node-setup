#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

CONFIG_DIR="$fixture/etc"
STATE_DIR="$fixture/state"
BACKUP_DIR="$fixture/backups"
NODE_DIR="$fixture/managed-node"
NODE_SECRET="$CONFIG_DIR/node.secret"
mkdir -p -- "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$NODE_DIR" \
    "$fixture/nginx/conf.d" "$fixture/nginx/sites-enabled" "$fixture/letsencrypt/renewal" "$fixture/legacy-node"

# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$PROJECT_DIR/lib/ui.sh"
# shellcheck source=lib/node.sh
source "$PROJECT_DIR/lib/node.sh"
# shellcheck source=lib/selfsteal.sh
source "$PROJECT_DIR/lib/selfsteal.sh"
# shellcheck source=lib/selfsteal-nginx.sh
source "$PROJECT_DIR/lib/selfsteal-nginx.sh"
# shellcheck source=lib/security.sh
source "$PROJECT_DIR/lib/security.sh"
# shellcheck source=lib/traffic-guard.sh
source "$PROJECT_DIR/lib/traffic-guard.sh"
# shellcheck source=lib/psiphon.sh
source "$PROJECT_DIR/lib/psiphon.sh"
# shellcheck source=lib/psiphon-profile.sh
source "$PROJECT_DIR/lib/psiphon-profile.sh"
# shellcheck source=lib/updates.sh
source "$PROJECT_DIR/lib/updates.sh"
# shellcheck source=lib/standalone.sh
source "$PROJECT_DIR/lib/standalone.sh"
# shellcheck source=lib/vpn-port.sh
source "$PROJECT_DIR/lib/vpn-port.sh"
# shellcheck source=lib/port-preflight.sh
source "$PROJECT_DIR/lib/port-preflight.sh"
# shellcheck source=lib/transaction.sh
source "$PROJECT_DIR/lib/transaction.sh"
# shellcheck source=lib/manager.sh
source "$PROJECT_DIR/lib/manager.sh"

export SELFSTEAL_NGINX_CONF_DIR="$fixture/nginx/conf.d"
export SELFSTEAL_NGINX_SITES_DIR="$fixture/nginx/sites-enabled"
export SELFSTEAL_RENEWAL_DIR="$fixture/letsencrypt/renewal"
export UFW_CONF_FILE="$fixture/ufw.conf"
printf 'ENABLED=yes\n' > "$UFW_CONF_FILE"
printf 'default.conf\n' > "$fixture/letsencrypt/renewal/node.example.com.conf"

cat > "$fixture/legacy-node/docker-compose.yml" <<'YML'
services:
  remnanode:
    container_name: remnanode
    image: remnawave/node:latest
    network_mode: host
    environment:
      - NODE_PORT=3003
      - SECRET_KEY=legacy-super-secret
YML

cat > "$SELFSTEAL_NGINX_CONF_DIR/selfsteal.conf" <<'NGINX'
server {
    listen 80;
    server_name node.example.com;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name node.example.com;
    return 204;
}
NGINX

_psiphon_environment="$fixture/vps-psiphon"
cat > "$_psiphon_environment" <<'ENV'
# vps-psiphon — written by psiphon_install.sh 1.3
BIND=127.0.0.1
SOCKS_PORT=1081
BULK_TEST_MB=0
EGRESS_REGION=DE
ENV

UI_INTERACTIVE=no
UI_CLEAR=no
UI_BOLD=''
UI_MUTED=''
UI_ACCENT=''
UI_OK=''
UI_WARN=''
UI_DANGER=''
UI_RESET=''
UI_COLUMNS=80
UI_RULE_WIDTH=58
UI_COMPACT=no

_node_docker() {
    case "$1 $2" in
        'container inspect')
            if [[ $* == *'Config.Labels "com.docker.compose.project"'* ]]; then
                printf 'remnanode\n'
            elif [[ $* == *'State.Status'* ]]; then
                printf 'running\t%s/legacy-node/docker-compose.yml\tremnawave/node:latest\n' "$fixture"
                printf 'SECRET_KEY=legacy-super-secret\nNODE_PORT=3003\n'
            elif [[ $* == *'range .Config.Env'* ]]; then
                printf 'SECRET_KEY=legacy-super-secret\nNODE_PORT=3003\n'
            elif [[ $* == *'vps-psiphon'* ]]; then
                return 0
            else
                return 0
            fi
            ;;
        'image inspect')
            printf 'v2.4.1\n'
            ;;
        'logs --tail')
            if [[ $* == *'vps-psiphon'* ]]; then
                printf '{"noticeType":"Tunnels","data":{"count":1}}\n'
            else
                printf 'remnanode ready secret=legacy-super-secret\n'
            fi
            ;;
        *) return 1 ;;
    esac
}

docker() {
    _node_docker "$@"
}

ss() {
    case "$*" in
        *'sport = :3003'*)
            printf 'LISTEN 0 511 *:3003 *:* users:(("rw-node",pid=4242,fd=10))\n'
            ;;
        *'sport = :1081'*)
            printf 'LISTEN 0 128 127.0.0.1:1081 0.0.0.0:*\n'
            ;;
        *'-lntup'*)
            printf 'tcp LISTEN 0 4096 *:443 *:* users:(("rw-core",pid=4243,fd=7))\n'
            ;;
        *)
            return 0
            ;;
    esac
}

_node_owns_listeners() { [[ $1 == *'pid=4242'* ]]; }
_selfsteal_verify_https() { [[ ${1:-} == node.example.com ]]; }
_selfsteal_validate_domain() { [[ ${NODE_DOMAIN:-} == node.example.com ]]; }
_selfsteal_external_renewal_active() { return 0; }
traffic_guard_firewall_active() { return 0; }
_traffic_guard_external_version() { printf '0.0.5\n'; }
systemctl() {
    case "$*" in
        'is-enabled ufw.service') printf 'enabled\n' ;;
        'is-active --quiet nginx.service'|'is-active --quiet vps-psiphon.service'|'is-active --quiet vps-psiphon-watchdog.timer') return 0 ;;
        *) return 1 ;;
    esac
}
ufw() {
    case "$*" in
        'status verbose')
            printf 'Status: active\nDefault: deny (incoming), allow (outgoing)\n\n3003/tcp ALLOW IN 192.0.2.10 # Remnawave\n443/tcp ALLOW IN Anywhere\n'
            ;;
        status)
            printf 'Status: active\n\n3003/tcp ALLOW IN 192.0.2.10 # Remnawave\n443/tcp ALLOW IN Anywhere\n'
            ;;
        *) return 1 ;;
    esac
}
fail2ban-client() {
    case "$*" in
        'status sshd') return 0 ;;
        -d)
            printf "['set', 'sshd', 'addaction', 'iptables-multiport']\n"
            printf "['set', 'sshd', 'action', 'iptables-multiport', 'blocktype', 'DROP']\n"
            ;;
        *) return 1 ;;
    esac
}
_psiphon_socks_ready() { [[ $1 == 1081 ]]; }
detect_ssh_port() { printf '22\n'; }
psiphon_latest_version() { printf '1.3\n'; }
_updates_github_tag() {
    case "$1" in
        dotX12/traffic-guard) printf 'v0.0.5\n' ;;
        *) printf 'v1.3.5\n' ;;
    esac
}
_node_latest_tag() { printf 'v2.4.1\n'; }
apt_installed_version() { return 1; }
timedatectl() { printf 'yes\n'; }
bbr_status() { printf 'Алгоритм TCP — bbr, очередь по умолчанию — fq\n'; }
ipv6_status() { printf 'IPv6 · отключён (sysctl)\n'; }
security_os_updates_status() { printf 'Автоматические обновления Ubuntu настроены.\n'; }
auto_update_status() { printf 'Автообновления выключены.\n'; }

# 1. Node compose parsing, status, and secret masking in logs.
parsed=$(_node_external_compose_parse "$fixture/legacy-node/docker-compose.yml")
[[ $parsed == $'remnawave/node:latest\t3003' ]]
[[ $(node_status required) == *'Нода (внешняя,'*'2.4.1 · TCP 3003 · работает.'* ]]
logs_out=$(node_logs 20)
[[ $logs_out == *'[скрыто]'* && $logs_out != *'legacy-super-secret'* ]]

# 2. Main menu status banner on legacy server.
menu_status=$(ui_menu_status main)
grep -Fq 'Внешняя нода · node.example.com · 3003/tcp' <<< "$menu_status"
grep -Fq 'UFW · TG · Psiphon' <<< "$menu_status"

# 3. Status, doctor, check_dns, and versions on legacy server.
status_out=$(status_all)
grep -Fq 'Нода (внешняя,' <<< "$status_out"
grep -Fq 'Self-steal (внешний,' <<< "$status_out"
grep -Fq 'iptables-multiport[blocktype=DROP]' <<< "$status_out"
grep -Fq 'TrafficGuard (0.0.5) включён.' <<< "$status_out"
grep -Fq 'Psiphon (внешний, 1.3) работает · SOCKS5 127.0.0.1:1081 · регион DE.' <<< "$status_out"

doctor_out=$(doctor)
grep -Fq '192.0.2.10' <<< "$doctor_out"
grep -Fq 'Время синхронизировано по NTP.' <<< "$doctor_out"
[[ $(check_dns '') == '' ]]

versions_out=$(show_versions)
grep -Fq 'Remnawave Node / Xray    2.4.1              2.4.1' <<< "$versions_out"
grep -Fq 'TrafficGuard             0.0.5              0.0.5' <<< "$versions_out"
grep -Fq 'Psiphon (vps-psiphon)    1.3                1.3' <<< "$versions_out"

# 4. Gemini template & Psiphon interactive update message on legacy Psiphon.
psiphon_profile all | jq -e '.outbounds[1].settings.port == 1081' >/dev/null
psi_upd=$(psiphon_update_action)
grep -Fq 'Установлен внешний vps-psiphon (1.3' <<< "$psi_upd"

# 5. Preflight defaults and legacy node TLS detection.
[[ $(security_ufw_panel_ips_for_port 3003) == 192.0.2.10 ]]
node_any_verify
preflight_out=$(standalone_port_preflight)
grep -Fq '3003/tcp · панель → нода · слушает' <<< "$preflight_out"

# 6. Legacy backup creation and non-destructive restore guard, plus legacy vpn-port detection.
export LEGACY_SNAPSHOT_PATHS="$fixture/legacy-node $SELFSTEAL_NGINX_CONF_DIR $UFW_CONF_FILE $_psiphon_environment"
backup_out=$(create_backup)
snap_id=${backup_out##*/}
snap_id=${snap_id%.}
[[ $(< "$BACKUP_DIR/$snap_id/scopes") == external ]]
if do_restore "$snap_id" >/dev/null 2>&1; then exit 1; fi
vpn_port_require_firewall
[[ $_VPN_PORT_LEGACY_MODE == yes && $NODE_PORT == 3003 && $PANEL_IPS == 192.0.2.10 && $VPN_PORTS == 443/tcp ]]

# 7. External node update safety guard.
update_msg=$(update_node force)
grep -Fq 'Найдена внешняя нода' <<< "$update_msg"

printf '%s\n' 'Проверены совместимость со старыми серверами и единое поведение всех пунктов.'
