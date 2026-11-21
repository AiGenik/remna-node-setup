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
        apt_install_current "${missing[@]}"
    fi
}

apt_installed_version() {
    local record status=0
    record=$(dpkg-query -W -f='${db:Status-Status}\t${Version}' "$1" 2>/dev/null) || status=$?
    if (( status > 1 )); then
        fail "Не удалось прочитать статус пакета $1."
        return 1
    fi
    if [[ $record == installed$'\t'* ]]; then printf '%s\n' "${record#*$'\t'}"; fi
}

_apt_refresh_indexes() {
    apt-get -o APT::Update::Error-Mode=any \
        -o Acquire::AllowInsecureRepositories=false \
        -o Acquire::AllowDowngradeToInsecureRepositories=false \
        -o Acquire::AllowWeakRepositories=false update || {
        fail 'Не удалось обновить индексы APT. Проверьте репозитории и повторите.'
        return 1
    }
}

_apt_package_plan() {
    local mode=$1 package installed policy candidate holds metadata
    shift
    holds=$(LC_ALL=C apt-mark showhold) || return 1
    for package in "$@"; do
        if [[ ! $package =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
            fail "Некорректное имя пакета APT: $package."
            return 1
        fi
        installed=$(apt_installed_version "$package") || return 1
        if [[ $mode == upgrade && -z $installed ]]; then continue; fi
        policy=$(LC_ALL=C apt-cache policy "$package") || return 1
        candidate=$(awk '$1 == "Candidate:" { print $2; exit }' <<< "$policy") || return 1
        if [[ -z $candidate || $candidate == '(none)' ]]; then
            if [[ $mode == install ]]; then
                fail "В подключённых репозиториях APT нет пакета $package."
                return 1
            fi
            warn "$package: APT не нашёл доступную версию."
            continue
        fi
        if [[ -n $installed ]] && dpkg --compare-versions "$candidate" le "$installed"; then
            if dpkg --compare-versions "$candidate" lt "$installed"; then
                warn "$package: установленная версия новее версии из репозитория."
            elif [[ $mode == install ]]; then
                # APT can designate a locally installed version as the candidate
                # even when it only knows the dpkg status record.
                metadata=$(LC_ALL=C apt-cache show "$package=$candidate") || return 1
                if ! grep -q '^Filename: ' <<< "$metadata"; then
                    fail "APT знает установленный $package, но не находит эту версию в подключённых репозиториях."
                    return 1
                fi
            fi
            continue
        fi
        if awk -F: -v name="$package" '$1 == name { held = 1 } END { exit !held }' <<< "$holds"; then
            if [[ $mode == install ]]; then
                fail "Обновление или установка $package до $candidate заблокированы apt-mark hold."
                return 1
            fi
            warn "$package: пропущен из-за apt-mark hold."
            continue
        fi
        printf '%s\t%s\t%s\n' "$package" "${installed:--}" "$candidate"
    done
}

_apt_apply_package_plan() {
    local mode=$1 plan=$2 package before candidate extra installed target
    local -a selection=() options=()
    [[ -n $plan ]] || return 0
    if [[ $mode == upgrade ]]; then options+=(--only-upgrade); fi
    while IFS=$'\t' read -r package before candidate extra; do
        if [[ ! $package =~ ^[a-z0-9][a-z0-9+.-]+$ ||
              ! $candidate =~ ^[0-9][a-zA-Z0-9.+:~-]*$ || -n $extra ]]; then
            fail 'Некорректный план обновления APT. Повторите проверку пакетов.'
            return 1
        fi
        installed=$(apt_installed_version "$package") || return 1
        if [[ $installed == "$candidate" ]]; then continue; fi
        if [[ $mode == upgrade && ( -z $installed || $installed != "$before" ) ]] ||
           { [[ -n $installed ]] && dpkg --compare-versions "$candidate" lt "$installed"; }; then
            fail "Версия пакета $package изменилась. Повторите проверку пакетов."
            return 1
        fi
        selection+=("$package=$candidate")
    done <<< "$plan"
    if (( ${#selection[@]} == 0 )); then return 0; fi

    # Keep existing dpkg conffiles. Dependencies may be added, but APT must
    # reject removals, downgrades, untrusted downloads, and held-package changes.
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
        -o DPkg::Options::=--force-confold -o APT::Ignore-Hold=false \
        -o APT::Get::allow-change-held-packages=false -o APT::Get::allow-downgrades=false \
        -o APT::Get::allow-unauthenticated=false -o APT::Get::force-yes=false \
        install -y --no-install-recommends --no-remove "${options[@]}" "${selection[@]}" || {
        fail 'APT не завершил установку выбранных пакетов.'
        return 1
    }
    for target in "${selection[@]}"; do
        package=${target%%=*}
        candidate=${target#*=}
        installed=$(apt_installed_version "$package") || return 1
        if [[ -z $installed ]] || ! dpkg --compare-versions "$installed" ge "$candidate"; then
            fail "Не удалось подтвердить установленную версию $package."
            return 1
        fi
    done
}

apt_install_current() {
    local plan
    (( $# )) || return 0
    _apt_refresh_indexes || return 1
    plan=$(_apt_package_plan install "$@") || return 1
    _apt_apply_package_plan install "$plan"
}

apt_upgrade_installed_preview() {
    (( $# )) || return 0
    _apt_refresh_indexes >&2 || return 1
    _apt_package_plan upgrade "$@"
}

apt_upgrade_installed_apply() {
    _apt_apply_package_plan upgrade "$1"
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
        answer=${answer:-$2}
        case "${answer,,}" in
            y|yes) printf 'yes\n'; return 0 ;;
            n|no) printf 'no\n'; return 0 ;;
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
      if .schema == 1 and (.node_port|type) == "number"
        and ((.ssh_port|type) == "number" or (.ssh_port == null and .security == "no"))
        and ((.security // "yes") | . == "yes" or . == "no")
        and ((.vpn_ports // "") | type) == "string"
      then [.node_domain, .node_port, .panel_ips, (.ssh_port // ""), .admin_ips, .selfsteal, .bbr, .traffic_guard,
            (.selfsteal_server // "caddy"), (.security // "yes"),
            (.vpn_ports // (if .security == "no" then "" else "443/tcp" end)),
            (if has("vpn_ports") then "yes" else "no" end)] | .[]
      else error("unsupported configuration")
      end' "$file") || return
    local fields
    mapfile -t fields <<< "$data"
    [[ ${#fields[@]} == 12 && ${fields[8]} =~ ^(caddy|nginx)$ ]] || return 1
    NODE_DOMAIN=${fields[0]}
    NODE_PORT=${fields[1]}
    PANEL_IPS=${fields[2]}
    SSH_PORT=${fields[3]}
    ADMIN_IPS=${fields[4]}
    ENABLE_SELFSTEAL=${fields[5]}
    ENABLE_BBR=${fields[6]}
    ENABLE_TRAFFIC_GUARD=${fields[7]}
    SELFSTEAL_SERVER=${fields[8]}
    # shellcheck disable=SC2034 # Consumed by the manager and security modules.
    ENABLE_SECURITY=${fields[9]}
    VPN_PORTS=${fields[10]}
    # shellcheck disable=SC2034 # Consumed by security_prompt_vpn_ports.
    VPN_PORTS_SAVED=${fields[11]}
}

save_config() {
    local tmp
    tmp=$(mktemp "$CONFIG_DIR/.node.XXXXXX") || return
    if ! jq -n --arg domain "$NODE_DOMAIN" --argjson port "$NODE_PORT" \
        --arg panel "$PANEL_IPS" --argjson ssh "${SSH_PORT:-null}" --arg admin "$ADMIN_IPS" \
        --arg selfsteal "$ENABLE_SELFSTEAL" --arg webserver "$SELFSTEAL_SERVER" \
        --arg bbr "$ENABLE_BBR" --arg traffic "$ENABLE_TRAFFIC_GUARD" \
        --arg security "${ENABLE_SECURITY:-yes}" --arg vpn "${VPN_PORTS-443/tcp}" \
        '{schema:1,node_domain:$domain,node_port:$port,panel_ips:$panel,ssh_port:$ssh,admin_ips:$admin,
          selfsteal:$selfsteal,selfsteal_server:$webserver,bbr:$bbr,traffic_guard:$traffic,security:$security,vpn_ports:$vpn}' > "$tmp"; then
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
