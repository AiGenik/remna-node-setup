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
export UFW_CONF_FILE="$fixture/ufw.conf"
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
ipv6_status() { :; }
security_os_updates_status() { :; }
psiphon_is_managed() { return 1; }

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

# shellcheck source=lib/updates.sh
source "$PROJECT_DIR/lib/updates.sh"
ui_section() { printf '%s\n' "$1"; }
NODE_DIR="$fixture/node"
mkdir -p -- "$NODE_DIR" "$STATE_DIR/nginx-certbot/config/renewal"
_updates_github_tag() { printf 'v9.9.9\n'; }
_node_latest_tag() { printf 'v3.9.0\n'; }
apt_installed_version() { return 1; }
timedatectl() { printf 'yes\n'; }
versions_out=$(show_versions)
grep -Fq 'remna-node-setup' <<< "$versions_out"
grep -Fq 'Remnawave Node / Xray' <<< "$versions_out"

dns=yes
fail2ban-client() {
    case "$*" in
        'status sshd') return 0 ;;
        'get sshd banaction') printf 'iptables-multiport[blocktype=DROP]\n' ;;
        *) return 1 ;;
    esac
}
certbot() { return 0; }
ss() { printf 'LISTEN 0 128 127.0.0.1:1080 0.0.0.0:*\n'; }
curl() {
    case "$*" in
        *api.ipify.org*) printf '198.51.100.77\n' ;;
        *) printf '200\n' ;;
    esac
}
export PSIPHON_GEMINI_CHECK_BIN="$fixture/mock-gemini-check"
cat > "$PSIPHON_GEMINI_CHECK_BIN" <<'GEM'
#!/usr/bin/env bash
printf '%s\n' 'ok — Gemini replies, and places this exit in Canada'
GEM
chmod +x "$PSIPHON_GEMINI_CHECK_BIN"
audit_out=$(audit_live)
grep -Fq 'Certbot dry-run' <<< "$audit_out"
grep -Fq '198.51.100.77' <<< "$audit_out"
grep -Fq 'сообщение отправлено и ответ получен' <<< "$audit_out"
grep -Fq 'YouTube прямой выход' <<< "$audit_out"

cat > "$PSIPHON_GEMINI_CHECK_BIN" <<'GEM'
#!/usr/bin/env bash
printf '%s\n' 'CAPTCHA — Google sends a browser on this exit to /sorry'
exit 3
GEM
if audit_live >/dev/null 2>&1; then exit 1; fi

printf '%s\n' 'Проверены диагностика DNS, Certbot, TrafficGuard, аудит, версии и состав снимка.'
