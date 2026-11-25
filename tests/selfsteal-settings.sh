#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PROJECT_DIR=$project
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
grep -Fq -- '-Server' "$CONFIG_DIR/Caddyfile"
DISABLE_IPV6=no
_selfsteal_ipv6_enabled() { [[ ${DISABLE_IPV6:-no} != yes ]]; }
_nginx_selfsteal_render_config tls > "$CONFIG_DIR/nginx.conf"
grep -Fq "https://node.example.com:9443\$request_uri" "$CONFIG_DIR/nginx.conf"
grep -Fq 'server_tokens off;' "$CONFIG_DIR/nginx.conf"
grep -Fq 'default_server;' "$CONFIG_DIR/nginx.conf"
grep -Fq 'listen [::]:80;' "$CONFIG_DIR/nginx.conf"
DISABLE_IPV6=yes
_nginx_selfsteal_render_config tls > "$CONFIG_DIR/nginx-v4.conf"
if grep -Fq 'listen [::]:80' "$CONFIG_DIR/nginx-v4.conf"; then exit 1; fi
DISABLE_IPV6=no
[[ $(selfsteal_panel_help) == *9443/tcp* ]]

_selfsteal_site="$CONFIG_DIR/site"
mkdir -p -- "$_selfsteal_site"
cat > "$_selfsteal_site/index.html" <<'LEGACY'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Полевые записи</title>
  <style>
    body { max-width: 42rem; margin: 12vh auto; padding: 0 1.5rem; font: 1.125rem/1.65 Georgia, serif; }
    h1 { line-height: 1.15; font-size: clamp(2.2rem, 7vw, 4.2rem); }
  </style>
</head>
<body>
  <main>
    <h1>Полевые записи</h1>
    <p>Короткие заметки о прогулках, погоде и смене сезонов.</p>
  </main>
</body>
</html>
LEGACY
_selfsteal_install_site_files
cmp -s "$PROJECT_DIR/templates/index.html" "$_selfsteal_site/index.html"
[[ -s $_selfsteal_site/robots.txt && -s $_selfsteal_site/favicon.svg ]]
printf 'custom site\n' > "$_selfsteal_site/index.html"
_selfsteal_install_site_files
[[ $(< "$_selfsteal_site/index.html") == 'custom site' ]]

VPN_PORTS=
SSH_PORT=
ENABLE_SECURITY=no
save_config
load_config
[[ -z $VPN_PORTS && -z $SSH_PORT && $ENABLE_SECURITY == no && $VPN_PORTS_SAVED == yes ]]
[[ $(selfsteal_redirect_host) == node.example.com ]]
printf '%s\n' 'Проверены старые настройки, сохранение портов и HTTPS-перенаправление Caddy/Nginx.'
