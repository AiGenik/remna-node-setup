#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
CONFIG_DIR=$(mktemp -d)
trap 'rm -rf -- "$CONFIG_DIR"' EXIT

cat > "$CONFIG_DIR/node.json" <<'JSON'
{"schema":1,"node_domain":"node.example.com","node_port":2222,"panel_ips":"192.0.2.20","ssh_port":22,
 "admin_ips":"","selfsteal":"yes","bbr":"no","traffic_guard":"no"}
JSON
load_config
[[ $SELFSTEAL_SERVER == caddy ]]
SELFSTEAL_SERVER=nginx
save_config
load_config
[[ $SELFSTEAL_SERVER == nginx && $ENABLE_SELFSTEAL == yes && $NODE_DOMAIN == node.example.com ]]
printf '%s\n' 'Старые настройки Caddy и сохранение выбора Nginx проверены.'
