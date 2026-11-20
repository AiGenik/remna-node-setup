#!/usr/bin/env bash

info() { printf '%s\n' "$*"; }
warn() { printf 'Внимание. %s\n' "$*" >&2; }
fail() { printf 'Ошибка. %s\n' "$*" >&2; return 1; }

version_get() {
    jq -er --arg key "$1" '.[$key] | select(type == "string" and length > 0)' "$PROJECT_DIR/versions.json"
}

ensure_host() {
    if [[ $EUID != 0 ]]; then
        fail 'Запустите команду через sudo.'
        return 1
    fi
    if ! grep -qx 'ID=ubuntu' /etc/os-release || ! grep -qx 'VERSION_ID="24.04"' /etc/os-release; then
        fail 'Поддерживается Ubuntu 24.04.'
        return 1
    fi
    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) fail 'Поддерживаются amd64 и arm64.'; return 1 ;;
    esac
    if [[ $(cat /proc/1/comm) != systemd ]]; then
        fail 'Для установки нужен VPS с systemd.'
        return 1
    fi
    command -v jq >/dev/null || fail 'Установите jq или запустите install.sh.'
}

active() {
    if systemctl is-active --quiet "$1"; then printf 'yes\n'; else printf 'no\n'; fi
}

enabled() {
    if systemctl is-enabled --quiet "$1"; then printf 'yes\n'; else printf 'no\n'; fi
}

apt_install_missing() {
    local package
    local -a missing=()
    for package in "$@"; do
        if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) != installed ]]; then
            missing+=("$package")
        fi
    done
    if (( ${#missing[@]} )); then
        apt-get -o APT::Update::Error-Mode=any update || return
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}

normalize_ips() {
    python3 - "$1" "${2:-address}" <<'PY'
import ipaddress
import sys

items = []
try:
    for entry in sys.argv[1].replace(",", " ").split():
        if "%" in entry:
            raise ValueError()
        address = ipaddress.ip_network(entry, strict=True) if sys.argv[2] == "network" and "/" in entry else ipaddress.ip_address(entry)
        if address.is_unspecified or address.is_loopback or address.is_multicast or address.is_link_local or getattr(address, "prefixlen", 1) == 0:
            raise ValueError()
        items.append(str(address))
except ValueError:
    print("Введите отдельные IP-адреса или сети подходящего формата.", file=sys.stderr)
    sys.exit(1)
print(" ".join(dict.fromkeys(items)))
PY
}

valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

valid_domain() {
    [[ $1 != .* && $1 != *. && $1 != *..* && ${#1} -le 253 && $1 == *.* ]] || return 1
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

prompt() {
    local message=$1 default=${2-} answer
    if [[ -n $default ]]; then
        printf '%s%s [%s]%s ' "${UI_BOLD:-}" "$message" "$default" "${UI_RESET:-}" >&2
    else
        printf '%s%s%s ' "${UI_BOLD:-}" "$message" "${UI_RESET:-}" >&2
    fi
    IFS= read -r answer || return
    printf '%s\n' "${answer:-$default}"
}

yes_no() {
    local answer choices='y/N'
    if [[ $2 == y ]]; then choices='Y/n'; fi
    while answer=$(prompt "$1 [$choices]"); do
        case "${answer:-$2}" in
            y|д|yes|да|Y|Д) printf 'yes\n'; return 0 ;;
            n|н|no|нет|N|Н) printf 'no\n'; return 0 ;;
        esac
        warn 'Введите y или n.'
        if [[ ${UI_INTERACTIVE:-no} != yes ]]; then return 1; fi
    done
    return 1
}

compose_value() {
    local value=${1%$'\r'} key=$2
    local prefix="^[[:blank:]]*(-[[:blank:]]*)?${key}[[:blank:]]*[=:][[:blank:]]*"
    if [[ $value =~ $prefix ]]; then
        value=${value#"${BASH_REMATCH[0]}"}
    fi
    value=${value#"${value%%[![:blank:]]*}"}
    value=${value%"${value##*[![:blank:]]}"}
    if [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value:1:-1}
    fi
    printf '%s\n' "$value"
}

ssh_context() {
    local value=${SSH_CONNECTION:-}
    local pid=$PPID candidate
    # sudo may discard SSH_CONNECTION. Read only this variable from ancestors.
    while [[ -z $value && $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
        if [[ -r /proc/$pid/environ ]]; then
            candidate=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^SSH_CONNECTION=//p' | head -n1) || candidate=
            value=$candidate
        fi
        pid=$(awk '$1 == "PPid:" {print $2}' "/proc/$pid/status" 2>/dev/null) || break
    done
    if [[ $value =~ ^[[:xdigit:].:]+\ [0-9]+\ [[:xdigit:].:]+\ [0-9]+$ ]]; then
        printf '%s\n' "$value"
    fi
    return 0
}

load_config() {
    local file=$CONFIG_DIR/node.json data
    [[ -r $file ]] || return 1
    data=$(jq -er '
      if .schema == 1 and (.node_port|type) == "number" and (.ssh_port|type) == "number"
      then [.node_domain, .node_port, .panel_ips, .ssh_port, .admin_ips, .selfsteal, .bbr, .traffic_guard,
            (.selfsteal_server // "caddy")] | .[]
      else error("unsupported configuration")
      end' "$file") || return
    local fields
    mapfile -t fields <<< "$data"
    [[ ${#fields[@]} == 9 && ${fields[8]} =~ ^(caddy|nginx)$ ]] || return 1
    NODE_DOMAIN=${fields[0]}
    NODE_PORT=${fields[1]}
    PANEL_IPS=${fields[2]}
    SSH_PORT=${fields[3]}
    ADMIN_IPS=${fields[4]}
    ENABLE_SELFSTEAL=${fields[5]}
    ENABLE_BBR=${fields[6]}
    ENABLE_TRAFFIC_GUARD=${fields[7]}
    SELFSTEAL_SERVER=${fields[8]}
}

save_config() {
    local tmp
    tmp=$(mktemp "$CONFIG_DIR/.node.XXXXXX") || return
    if ! jq -n --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg panel "$PANEL_IPS" --argjson ssh "$SSH_PORT" --arg admin "$ADMIN_IPS" \
        --arg selfsteal "$ENABLE_SELFSTEAL" --arg webserver "$SELFSTEAL_SERVER" \
        --arg bbr "$ENABLE_BBR" --arg traffic "$ENABLE_TRAFFIC_GUARD" \
        '{schema:1,node_domain:$domain,node_port:$port,panel_ips:$panel,ssh_port:$ssh,admin_ips:$admin,
          selfsteal:$selfsteal,selfsteal_server:$webserver,bbr:$bbr,traffic_guard:$traffic}' > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$CONFIG_DIR/node.json"
}

save_secret() {
    local tmp
    [[ -n ${NEW_NODE_SECRET:-} ]] || return 0
    tmp=$(mktemp "$CONFIG_DIR/.secret.XXXXXX") || return
    if ! printf '%s\n' "$NEW_NODE_SECRET" > "$tmp" || ! mv -f -- "$tmp" "$NODE_SECRET"; then
        rm -f -- "$tmp"
        return 1
    fi
    unset NEW_NODE_SECRET
}
