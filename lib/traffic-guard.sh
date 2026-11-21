#!/usr/bin/env bash

traffic_guard_download() {
    curl --disable --fail --location --silent --show-error \
        --proto '=https' --proto-redir '=https' \
        --max-redirs 5 --max-filesize "${3:-1048576}" \
        --connect-timeout 10 --max-time 45 --retry 1 --retry-max-time 50 \
        --output "$2" "$1"
}

traffic_guard_check_hash() {
    local file=$1 expected=$2 result
    [[ -f $file && $expected =~ ^[a-f0-9]{64}$ ]] || return 1
    result=$(sha256sum -- "$file") || return 1
    [[ ${result%% *} == "$expected" ]]
}

traffic_guard_latest_release() {
    local architecture=$1 metadata=$2
    local api='https://api.github.com/repos/dotX12/traffic-guard/releases/latest'
    local assets='https://github.com/dotX12/traffic-guard/releases/download'
    local name="traffic-guard-linux-$architecture"
    traffic_guard_download "$api" "$metadata" || { fail "Не удалось получить текущий релиз TrafficGuard."; return 1; }
    jq -er --arg assets "$assets" --arg name "$name" '
        def stable_tag: strings | test("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$");
        select(.draft == false and .prerelease == false and (.tag_name | stable_tag))
        | .tag_name as $tag
        | [.assets[] | select(.name == $name)]
        | select(length == 1)
        | .[0]
        | select(.state == "uploaded" and (.digest | strings | test("^sha256:[0-9a-f]{64}$")))
        | select(.size | numbers | . > 0 and . <= 52428800 and . == floor)
        | select(.browser_download_url == ($assets + "/" + $tag + "/" + $name))
        | [$tag, (.digest | ltrimstr("sha256:")), .browser_download_url, .size] | @tsv
    ' "$metadata" || { fail "Релиз TrafficGuard не содержит проверяемый стабильный архив для $architecture."; return 1; }
}

traffic_guard_latest_list() {
    local dir=$1 repo='shadow-netlab/traffic-guard-lists' path='public/antiscanner.list'
    local api commit url blob
    api="https://api.github.com/repos/$repo"
    traffic_guard_download "$api/commits?path=public%2Fantiscanner.list&per_page=1" "$dir/commits.json" ||
        { fail "Не удалось узнать текущую версию списка TrafficGuard."; return 1; }
    commit=$(jq -er '
        select(type == "array" and length == 1)
        | .[0].sha | strings | select(test("^[a-f0-9]{40}$"))
    ' "$dir/commits.json") || { fail "GitHub не вернул корректный коммит списка TrafficGuard."; return 1; }
    url="https://raw.githubusercontent.com/$repo/$commit/$path"
    traffic_guard_download "$api/contents/$path?ref=$commit" "$dir/list.json" ||
        { fail "Не удалось получить сведения о списке TrafficGuard."; return 1; }
    blob=$(jq -er --arg path "$path" --arg url "$url" '
        select(.type == "file" and .path == $path and .download_url == $url)
        | select(.size | numbers | . > 0 and . <= 524288 and . == floor)
        | .sha | strings | select(test("^[a-f0-9]{40}$"))
    ' "$dir/list.json") || { fail "Официальный список TrafficGuard не прошёл проверку метаданных."; return 1; }
    traffic_guard_download "$url" "$dir/list" 524288 ||
        { fail "Не удалось загрузить список TrafficGuard."; return 1; }
    if ! python3 - "$dir/list" "$blob" <<'PY'
import hashlib
import sys
from pathlib import Path

body = Path(sys.argv[1]).read_bytes()
header = f"blob {len(body)}\0".encode("ascii")
sys.exit(hashlib.sha1(header + body, usedforsecurity=False).hexdigest() != sys.argv[2])
PY
    then
        fail "Список TrafficGuard не совпадает с файлом из указанного коммита."
        return 1
    fi
    printf '%s\t%s\n' "$commit" "$url"
}

traffic_guard_validate_list() {
    local list=$1 expected=$2
    python3 - "$list" "$expected" "${PANEL_IPS:-} ${ADMIN_IPS:-} ${ADMIN_IP:-}" <<'PY'
import ipaddress
import sys
from pathlib import Path

try:
    protected = [
        ipaddress.ip_network(address, strict=False)
        for address in (sys.argv[3] + " 127.0.0.0/8 ::1").split()
    ]
    active = set()
    for raw in Path(sys.argv[1]).read_text(encoding="ascii").splitlines():
        value = raw.strip()
        if not value or value.startswith("#"):
            continue
        network = ipaddress.ip_network(value, strict=False)
        if network.prefixlen == 0:
            raise ValueError("список содержит маршрут по умолчанию")
        if any(network.version == peer.version and network.overlaps(peer) for peer in protected):
            raise ValueError(f"подсеть {network} включает доверенный IP или подсеть")
        active.add(str(network))
    if not active:
        raise ValueError("список пуст")
    Path(sys.argv[2]).write_text("\n".join(sorted(active)) + "\n", encoding="ascii")
    print(f"Проверено записей TrafficGuard: {len(active)}.")
except (OSError, ValueError) as exc:
    print(f"TrafficGuard: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

traffic_guard_firewall_active() {
    security_ufw_active &&
        iptables -w -C ufw-before-input -j SCANNERS-BLOCK 2>/dev/null &&
        ip6tables -w -C ufw6-before-input -j SCANNERS-BLOCK 2>/dev/null &&
        iptables -w -C SCANNERS-BLOCK -m set --match-set SCANNERS-BLOCK-V4 src -j DROP 2>/dev/null &&
        ip6tables -w -C SCANNERS-BLOCK -m set --match-set SCANNERS-BLOCK-V6 src -j DROP 2>/dev/null
}

traffic_guard_verify_sets() {
    local dir=$1
    ipset save SCANNERS-BLOCK-V4 > "$dir/running-v4" || return 1
    ipset save SCANNERS-BLOCK-V6 > "$dir/running-v6" || return 1
    python3 - "$dir/expected" "$dir/running-v4" "$dir/running-v6" /etc/ipset.conf <<'PY'
import ipaddress
import sys
from pathlib import Path

names = {"SCANNERS-BLOCK-V4", "SCANNERS-BLOCK-V6"}

def entries(paths):
    result = set()
    for path in paths:
        for line in Path(path).read_text(encoding="ascii").splitlines():
            tokens = line.split()
            if len(tokens) >= 3 and tokens[0] == "add" and tokens[1] in names:
                result.add(str(ipaddress.ip_network(tokens[2], strict=False)))
    return result

try:
    expected = set(Path(sys.argv[1]).read_text(encoding="ascii").splitlines())
    live = entries(sys.argv[2:4])
    persistent = entries(sys.argv[4:])
    if not expected or live != expected or persistent != expected:
        raise ValueError("активный или сохранённый набор отличается от проверенного списка")
except (OSError, ValueError) as exc:
    print(f"TrafficGuard: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

traffic_guard_verify() {
    local dir=$1
    traffic_guard_firewall_active &&
        systemctl is-enabled --quiet antiscan-ipset-restore.service &&
        systemctl is-enabled --quiet antiscan-move-rules.service &&
        traffic_guard_verify_sets "$dir"
}

traffic_guard_no_downgrade() {
    local version=$1 installed=$2 old_version
    [[ -f $installed/version ]] || return 0
    old_version=$(< "$installed/version")
    old_version=${old_version#v}
    if [[ ! $old_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "Версия установленного TrafficGuard повреждена."
        return 1
    fi
    if ! dpkg --compare-versions "$version" ge "$old_version"; then
        fail "Установленный TrafficGuard $old_version новее текущего стабильного релиза $version."
        return 1
    fi
}

traffic_guard_prepare() {
    local dir=$1 installed="$STATE_DIR/traffic-guard"
    local architecture metadata tag version checksum asset_url asset_size list commit list_url

    case $(uname -m) in
        x86_64) architecture=amd64 ;;
        aarch64) architecture=arm64 ;;
        *) fail "TrafficGuard доступен для amd64 и arm64."; return 1 ;;
    esac
    rm -f -- "$dir/refs" "$dir/traffic-guard" || return 1
    metadata=$(traffic_guard_latest_release "$architecture" "$dir/release.json") || return 1
    IFS=$'\t' read -r tag checksum asset_url asset_size <<< "$metadata"
    version=${tag#v}
    traffic_guard_no_downgrade "$version" "$installed" || return 1

    list=$(traffic_guard_latest_list "$dir") || return 1
    IFS=$'\t' read -r commit list_url <<< "$list"
    traffic_guard_validate_list "$dir/list" "$dir/expected" || return 1
    if ! traffic_guard_check_hash "$installed/traffic-guard" "$checksum"; then
        traffic_guard_download "$asset_url" "$dir/traffic-guard" "$asset_size" ||
            { fail "Не удалось загрузить TrafficGuard $version."; return 1; }
        traffic_guard_check_hash "$dir/traffic-guard" "$checksum" ||
            { fail "Контрольная сумма TrafficGuard не совпала."; return 1; }
        chmod 0700 "$dir/traffic-guard" || return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$version" "$checksum" "$commit" "$list_url" > "$dir/refs"
}

traffic_guard_apply() (
    local installed="$STATE_DIR/traffic-guard"
    local version checksum commit url work_dir=${1:-} binary set_names
    security_ufw_active || { fail "Перед TrafficGuard включите защиту UFW."; return 1; }

    if [[ ! -f $installed/version ]]; then
        set_names=$(ipset list -n) || return 1
        if [[ -e /etc/ipset.conf ||
              -e /etc/systemd/system/antiscan-ipset-restore.service ||
              -e /etc/systemd/system/antiscan-move-rules.service ||
              $set_names == *SCANNERS-BLOCK* ]] ||
            iptables -w -S SCANNERS-BLOCK >/dev/null 2>&1 ||
            ip6tables -w -S SCANNERS-BLOCK >/dev/null 2>&1; then
            fail "Обнаружен ранее настроенный TrafficGuard или общий /etc/ipset.conf."
            return 1
        fi
    fi

    if [[ -z $work_dir ]]; then
        work_dir=$(mktemp -d "$STATE_DIR/.traffic-guard.XXXXXX") || return 1
        # shellcheck disable=SC2064
        trap "rm -rf -- $(printf '%q' "$work_dir")" EXIT
        traffic_guard_prepare "$work_dir" || return 1
    fi
    IFS=$'\t' read -r version checksum commit url < "$work_dir/refs" ||
        { fail "Подготовка TrafficGuard не завершена."; return 1; }
    traffic_guard_no_downgrade "$version" "$installed" || return 1

    binary="$work_dir/traffic-guard"
    if [[ ! -f $binary ]]; then binary="$installed/traffic-guard"; fi
    traffic_guard_check_hash "$binary" "$checksum" ||
        { fail "Контрольная сумма TrafficGuard не совпала."; return 1; }
    if [[ $binary == "$installed/traffic-guard" && -f $installed/version &&
          $(< "$installed/version") == "$version" ]] &&
         traffic_guard_verify "$work_dir" 2>/dev/null; then
        info "TrafficGuard $version включён, правила актуальны (список ${commit:0:12})."
    else
        # The upstream utility fetches the same commit-addressed URL. Verify the
        # actual active and reboot-persistent rules independently of its exit code.
        LC_ALL=C "$binary" full --urls "$url" || return 1
        traffic_guard_verify "$work_dir" || { fail "Не удалось подтвердить правила TrafficGuard для IPv4 и IPv6."; return 1; }
        install -d -m 0700 "$installed" || return 1
        if [[ $binary != "$installed/traffic-guard" ]]; then
            install -m 0700 "$binary" "$installed/traffic-guard" || return 1
        fi
        printf '%s\n' "$version" > "$installed/version" || return 1
        info "TrafficGuard $version включён (список ${commit:0:12})."
    fi
    printf '%s\n' "$commit" > "$installed/list-commit"
)

traffic_guard_status() {
    local version_file="$STATE_DIR/traffic-guard/version" commit_file="$STATE_DIR/traffic-guard/list-commit"
    local commit suffix=''
    if [[ ! -f $version_file ]]; then
        if [[ ${1-} == required ]]; then fail 'TrafficGuard включён в настройках, но не установлен.'; return 1; fi
        info "TrafficGuard выключен."
    elif traffic_guard_firewall_active; then
        if [[ -r $commit_file ]]; then
            commit=$(< "$commit_file")
            if [[ $commit =~ ^[a-f0-9]{40}$ ]]; then suffix=" · база ${commit:0:12}"; fi
        fi
        info "TrafficGuard $(< "$version_file") включён$suffix."
    else
        warn "TrafficGuard $(< "$version_file") установлен. Правила неактивны."
        if [[ ${1-} == required ]]; then return 1; fi
    fi
}

traffic_guard_capture_runtime() {
    local dir=$1
    local saved set_name tool
    if command -v ipset >/dev/null; then
        saved=$(ipset list -n) || return 1
        for set_name in SCANNERS-BLOCK-V4 SCANNERS-BLOCK-V6; do
            if grep -Fxq -- "$set_name" <<< "$saved"; then
                ipset save "$set_name" > "$dir/$set_name" || return 1
            fi
        done
    fi
    for tool in iptables ip6tables; do
        if command -v "$tool" >/dev/null && "$tool" -w -S SCANNERS-BLOCK >/dev/null 2>&1; then
            touch "$dir/$tool-chain" || return 1
        fi
    done
    touch "$dir/traffic-guard-captured"
}

traffic_guard_restore_before_ufw() {
    local dir=$1
    local set_name tool
    [[ -f $dir/traffic-guard-captured ]] || return 0

    for set_name in SCANNERS-BLOCK-V4 SCANNERS-BLOCK-V6; do
        [[ -s $dir/$set_name ]] || continue
        if ipset list "$set_name" -terse >/dev/null 2>&1; then
            ipset flush "$set_name" || return 1
        fi
        ipset restore -exist -f "$dir/$set_name" || return 1
    done
    for tool in iptables ip6tables; do
        if [[ -f $dir/$tool-chain ]] && ! "$tool" -w -S SCANNERS-BLOCK >/dev/null 2>&1; then
            "$tool" -w -N SCANNERS-BLOCK || return 1
        fi
    done
}

traffic_guard_restore_after_ufw() {
    local dir=$1
    local tool hook set_name
    [[ -f $dir/traffic-guard-captured ]] || return 0

    for tool in iptables ip6tables; do
        [[ ! -f $dir/$tool-chain ]] || continue
        if command -v "$tool" >/dev/null && "$tool" -w -S SCANNERS-BLOCK >/dev/null 2>&1; then
            if [[ $tool == iptables ]]; then hook=ufw-before-input; else hook=ufw6-before-input; fi
            while "$tool" -w -C "$hook" -j SCANNERS-BLOCK >/dev/null 2>&1; do
                "$tool" -w -D "$hook" -j SCANNERS-BLOCK || return 1
            done
            while "$tool" -w -C INPUT -j SCANNERS-BLOCK >/dev/null 2>&1; do
                "$tool" -w -D INPUT -j SCANNERS-BLOCK || return 1
            done
            "$tool" -w -F SCANNERS-BLOCK || return 1
            "$tool" -w -X SCANNERS-BLOCK || return 1
        fi
    done
    for set_name in SCANNERS-BLOCK-V4 SCANNERS-BLOCK-V6; do
        if [[ ! -e $dir/$set_name ]] && command -v ipset >/dev/null &&
           ipset list "$set_name" -terse >/dev/null 2>&1; then
            ipset destroy "$set_name" || return 1
        fi
    done
}
