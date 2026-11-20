#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/selfsteal.sh
source "$project/lib/selfsteal.sh"
# shellcheck source=lib/selfsteal-nginx.sh
source "$project/lib/selfsteal-nginx.sh"
CONFIG_DIR=$(mktemp -d)
STATE_DIR="$CONFIG_DIR/state"
trap 'rm -rf -- "$CONFIG_DIR"' EXIT

cat > "$CONFIG_DIR/node.json" <<'JSON'
{"schema":1,"node_domain":"node.example.com","node_port":2222,"panel_ips":"192.0.2.20","ssh_port":22,
 "admin_ips":"","selfsteal":"yes","bbr":"no","traffic_guard":"no"}
JSON
load_config
[[ $SELFSTEAL_SERVER == caddy && $ENABLE_SECURITY == yes && $VPN_PORTS == 443/tcp && $VPN_PORTS_SAVED == no ]]
SELFSTEAL_SERVER=nginx
VPN_PORTS='4000/udp 9443/tcp 443/tcp'
save_config
load_config
[[ $SELFSTEAL_SERVER == nginx && $ENABLE_SELFSTEAL == yes && $NODE_DOMAIN == node.example.com &&
   $VPN_PORTS == '4000/udp 9443/tcp 443/tcp' && $VPN_PORTS_SAVED == yes ]]
_selfsteal_render_config "$CONFIG_DIR/Caddyfile"
grep -Fq 'https://node.example.com:9443{uri}' "$CONFIG_DIR/Caddyfile"
_nginx_selfsteal_render_config tls > "$CONFIG_DIR/nginx.conf"
grep -Fq "https://node.example.com:9443\$request_uri" "$CONFIG_DIR/nginx.conf"
[[ $(selfsteal_panel_help) == *9443/tcp* ]]

VPN_PORTS=
SSH_PORT=
ENABLE_SECURITY=no
save_config
load_config
[[ -z $VPN_PORTS && -z $SSH_PORT && $ENABLE_SECURITY == no && $VPN_PORTS_SAVED == yes ]]
[[ $(selfsteal_redirect_host) == node.example.com ]]
printf '%s\n' 'Проверены старые настройки, сохранение портов и HTTPS-перенаправление Caddy/Nginx.'
