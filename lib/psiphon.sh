#!/usr/bin/env bash

# Reviewed v1.3 installer (the annotated tag resolves to this commit).
PSIPHON_UPSTREAM_VERSION=1.3
PSIPHON_UPSTREAM_COMMIT=3e48128ffcf32fead66e330b1749e1981a9e1c9f
PSIPHON_INSTALLER_SHA256=1428beeaab91de159e5354308a8b30948ca6c406bfa37a5d5298071e0f6319d2
PSIPHON_IMAGE=swarupsengupta2007/psiphon@sha256:ed678abc7145e0fb550eb889a5dfed74bd8495bca16b958d6b7ac582d869bfe6
_psiphon_service=vps-psiphon.service
_psiphon_timer=vps-psiphon-watchdog.timer
_psiphon_watchdog=vps-psiphon-watchdog.service
_psiphon_environment=/etc/default/vps-psiphon
_psiphon_install_paths=(
    /etc/default/vps-psiphon
    /etc/systemd/system/vps-psiphon.service
    /etc/systemd/system/vps-psiphon-watchdog.service
    /etc/systemd/system/vps-psiphon-watchdog.timer
    /usr/local/sbin/vps-psiphon
    /usr/local/sbin/vps-psiphon-run
    /usr/local/sbin/vps-psiphon-prestart
    /usr/local/sbin/vps-psiphon-watchdog
    /usr/local/sbin/vps-psiphon-gemini-check
    /usr/local/sbin/vps-psiphon-advance-region
    /opt/vps-psiphon
)

_psiphon_marker() {
    printf '%s/psiphon.json\n' "$STATE_DIR"
}

psiphon_is_managed() {
    local file
    file=$(_psiphon_marker) || return 1
    [[ -f $file && ! -L $file ]] && [[ $(stat -c '%u %a' -- "$file") == '0 600' ]] || return 1
    jq -e '
        .schema == 1 and .upstream == "Chara-Freedom/vps-psiphon" and
        (.commit | test("^[a-f0-9]{40}$")) and
        (.version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
        (.image | test("^swarupsengupta2007/psiphon@sha256:[a-f0-9]{64}$")) and
        (.region | test("^(|[A-Z]{2})$")) and
        (.port | type == "number" and . >= 1 and . <= 65535 and . == floor)
    ' "$file" >/dev/null 2>&1
}

_psiphon_existing_install() {
    local path state
    for path in "${_psiphon_install_paths[@]}" "$(_psiphon_marker)"; do
        if [[ -e $path || -L $path ]]; then return 0; fi
    done
    state=$(systemctl show -p LoadState --value "$_psiphon_service" 2>/dev/null) || state=not-found
    if [[ -n $state && $state != not-found ]]; then return 0; fi
    _node_docker container inspect vps-psiphon >/dev/null 2>&1
}

_psiphon_region() {
    local region
    region=$(LC_ALL=C tr '[:lower:]' '[:upper:]' <<< "$1") || return 1
    case $region in
        AUTO|'') printf '\n' ;;
        AE|AR|AT|AU|BE|BG|BR|CA|CH|CL|CO|CZ|DE|DK|EE|ES|FI|FR|GB|GR|HK|HR|HU|ID|IE|IN|IS|IT|JP|KE|KR|LT|LV|MX|MY|NL|NO|NZ|PL|PT|RO|RS|SE|SG|SK|TW|UA|US|ZA)
            printf '%s\n' "$region" ;;
        *) fail 'Укажите auto или код страны из списка Psiphon, например DE, NL, US.' ;;
    esac
}

_psiphon_default_port() {
    local port listeners
    for ((port = 1080; port <= 1090; port++)); do
        listeners=$(ss -H -ltn "sport = :$port") || return 1
        if [[ -z $listeners ]]; then printf '%s\n' "$port"; return 0; fi
    done
}

_psiphon_input_port() {
    valid_port "$1" || { fail 'Укажите корректный порт SOCKS5.'; return 1; }
    printf '%s\n' "$1"
}

_psiphon_docker_ready() {
    local context version mode
    context=$(env -u DOCKER_CONTEXT -u DOCKER_HOST docker context show 2>/dev/null) ||
        { fail 'Для Psiphon нужен работающий локальный Docker Engine.'; return 1; }
    [[ $context == default ]] || { fail 'Для Psiphon нужен локальный контекст Docker default.'; return 1; }
    version=$(_node_docker version --format '{{.Server.Version}}') || return 1
    if [[ ! $version =~ ^([0-9]+)\.[0-9]+\.[0-9]+ || ${BASH_REMATCH[1]} -lt 28 ]]; then
        fail 'Для безопасной публикации SOCKS5 на loopback нужен Docker Engine 28 или новее.'
        return 1
    fi
    if [[ -e /etc/docker/daemon.json ]] &&
        ! jq -e '.["allow-direct-routing"] != true' /etc/docker/daemon.json >/dev/null; then
        fail 'Psiphon требует стандартный Docker bridge без прямой маршрутизации.'
        return 1
    fi
    if ! _node_docker network inspect --format '{{json .Options}}' bridge |
        jq -e '
            def nat($family):
                .["com.docker.network.bridge.gateway_mode_" + $family] // "nat"
                | . == "nat" or . == "isolated";
            nat("ipv4") and nat("ipv6") and
            (.["com.docker.network.bridge.trusted_host_interfaces"] // "") == ""
        ' >/dev/null; then
        fail 'Psiphon требует стандартный Docker bridge без прямой маршрутизации.'
        return 1
    fi
    mode=$(_node_docker container inspect --format '{{.HostConfig.NetworkMode}}' remnanode 2>/dev/null) || mode=
    if [[ -n $mode && $mode != host ]]; then
        fail 'Remnanode должен работать в сети хоста для доступа к 127.0.0.1.'
        return 1
    fi
}

_psiphon_port_bindings_ok() {
    local port=$1 bindings
    bindings=$(_node_docker container inspect --format '{{json .HostConfig.PortBindings}}' vps-psiphon 2>/dev/null) ||
        return 1
    jq -e --arg port "$port" '
        . == {($port + "/tcp"): [{HostIp: "127.0.0.1", HostPort: $port}]}
    ' <<< "$bindings" >/dev/null
}

_psiphon_socks_ready() {
    python3 - "$1" <<'PY'
import socket
import sys

try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2) as connection:
        connection.sendall(b"\x05\x01\x00")
        with connection.makefile("rb") as reply:
            sys.exit(reply.read(2) != b"\x05\x00")
except OSError:
    sys.exit(1)
PY
}

_psiphon_verify() {
    local region=$1 port=$2 image=$3 config actual
    systemctl is-active --quiet "$_psiphon_service" || return 1
    _psiphon_port_bindings_ok "$port" || return 1
    [[ -f $_psiphon_environment && ! -L $_psiphon_environment ]] &&
        [[ $(stat -c '%u %a' -- "$_psiphon_environment") == '0 600' ]] || return 1
    config=$(awk '/^(IMAGE|BIND|SOCKS_PORT|PUBLISH_HTTP|EGRESS_REGION)=/' "$_psiphon_environment" | LC_ALL=C sort) ||
        return 1
    [[ $config == "$(printf '%s\n' 'BIND=127.0.0.1' "EGRESS_REGION=$region" "IMAGE=$image" 'PUBLISH_HTTP=0' "SOCKS_PORT=$port")" ]] ||
        return 1
    actual=$(_node_docker container inspect --format '{{.State.Status}} {{.Config.Image}}' vps-psiphon) || return 1
    [[ $actual == "running $image" ]] || return 1
    jq -e --argjson port "$port" '
        .DisableLocalHTTPProxy == true and .LocalSocksProxyPort == $port
    ' /opt/vps-psiphon/config/psiphon.config >/dev/null &&
        _psiphon_socks_ready "$port"
}

psiphon_outbound() {
    local port=${1:-}
    if [[ -z $port ]]; then
        psiphon_is_managed || { fail 'Сначала настройте Psiphon.'; return 1; }
        port=$(jq -er '.port' "$(_psiphon_marker)") || return 1
    fi
    valid_port "$port" || { fail 'Укажите корректный порт SOCKS5.'; return 1; }
    jq -n --argjson port "$port" '{
        tag: "psiphon-out", protocol: "socks", settings: {address: "127.0.0.1", port: $port}
    }'
}

_psiphon_download_installer() {
    local destination=$1 checksum
    curl -q --proto '=https' --fail --silent --show-error --connect-timeout 8 --max-time 25 \
        --max-filesize 262144 --output "$destination" \
        "https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/$PSIPHON_UPSTREAM_COMMIT/psiphon_install.sh" ||
        { fail 'Не удалось скачать проверенный установщик Psiphon.'; return 1; }
    checksum=$(sha256sum < "$destination") || return 1
    [[ ${checksum%% *} == "$PSIPHON_INSTALLER_SHA256" ]] ||
        { fail 'Контрольная сумма установщика Psiphon не совпала.'; return 1; }
}

_psiphon_adapt_installer() {
    python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
text = source.read_text()
continuation = chr(92) + "\n"
edits = [
    # Skip the upstream status probe, which sends a sample prompt to Gemini.
    ("/usr/local/sbin/$P status\n", ""),
    # Fail closed if the launcher could not read the image config template.
    ('rm -f "$cfg.new"\n', 'rm -f "$cfg.new"\n[ -f "$cfg" ] || exit 1\n'),
    # Upstream --no-http disables publication, not the internal listener.
    ("  setline DisableTactics true\n",
     '  setkey LocalSocksProxyPort "$SOCKS_PORT"\n'
     "  setline DisableLocalHTTPProxy true\n"
     "  setline DisableTactics true\n"),
    # The image's stock healthcheck checks its HTTP listener, which we disable.
    ('  "${PUB[@]}" ' + continuation,
     '  "${PUB[@]}" ' + continuation
     + """  --health-cmd 'netstat -ltn | grep -Eq ":${SOCKS_PORT}[[:space:]]"' """ + continuation),
]
for original, replacement in edits:
    if text.count(original) != 1:
        sys.exit("Ожидаемый фрагмент установщика Psiphon отсутствует или повторяется.")
    text = text.replace(original, replacement, 1)
target.write_text(text)
PY
}

_psiphon_rollback_install() {
    local backup=$1 old_active=$2 old_enabled=$3
    local errors=0 state unit
    for unit in "$_psiphon_timer" "$_psiphon_watchdog" "$_psiphon_service"; do
        state=$(systemctl show -p LoadState --value "$unit") || { errors=1; continue; }
        if [[ $state != not-found ]]; then systemctl stop "$unit" || errors=1; fi
    done
    if [[ $(enabled "$_psiphon_service") == yes ]]; then
        systemctl disable "$_psiphon_service" || errors=1
    fi
    if _node_docker container inspect vps-psiphon >/dev/null 2>&1; then
        _node_docker container rm --force vps-psiphon >/dev/null || errors=1
    fi
    path_restore "$backup" "${_psiphon_install_paths[@]}" || errors=1
    systemctl daemon-reload || errors=1
    restore_service "$_psiphon_service" "$old_active" "$old_enabled" || errors=1
    return "$errors"
}

_psiphon_finish_install() {
    local status=$1 stage=$2 touched=$3 old_active=$4 old_enabled=$5
    if (( status != 0 )) && [[ $touched == yes ]]; then
        if ! _psiphon_rollback_install "$stage" "$old_active" "$old_enabled"; then
            warn "Автоматический откат Psiphon завершился с ошибкой. Копия файлов сохранена в $stage."
            return
        fi
    fi
    rm -rf -- "$stage"
}

_psiphon_install() (
    local region=$1 port=$2 old_active old_enabled managed=no stage path listeners touched=no
    _psiphon_docker_ready || return 1
    for path in "/etc/systemd/system/$_psiphon_service.d" "/etc/systemd/system/$_psiphon_timer.d"; do
        if [[ -e $path || -L $path ]]; then
            fail "Обнаружены внешние настройки systemd в $path."
            return 1
        fi
    done
    if psiphon_is_managed; then
        managed=yes
        for path in "${_psiphon_install_paths[@]}"; do
            [[ ! -L $path ]] || { fail "Обнаружена сторонняя ссылка $path."; return 1; }
        done
        if [[ $(active "$_psiphon_timer") == yes || $(enabled "$_psiphon_timer") == yes ||
              $(active "$_psiphon_watchdog") == yes ]]; then
            fail 'Перед настройкой отключите вручную запущенный watchdog Psiphon.'
            return 1
        fi
    elif _psiphon_existing_install; then
        fail 'Обнаружен сторонний vps-psiphon. Сохранены его файлы и сервис.'
        return 1
    fi
    listeners=$(ss -H -ltn "sport = :$port") || return 1
    if [[ -n $listeners ]] &&
        { [[ $managed != yes ]] || ! _psiphon_port_bindings_ok "$port"; }; then
        fail "Порт TCP $port занят. Укажите свободный порт SOCKS5."
        return 1
    fi
    old_active=$(active "$_psiphon_service") || return 1
    old_enabled=$(enabled "$_psiphon_service") || return 1
    stage=$(mktemp -d "$STATE_DIR/.psiphon.XXXXXX") || return 1
    trap '_psiphon_finish_install "$?" "$stage" "$touched" "$old_active" "$old_enabled"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    _psiphon_download_installer "$stage/upstream.sh" || return 1
    _psiphon_adapt_installer "$stage/upstream.sh" "$stage/install.sh" || return 1
    bash -n "$stage/install.sh" || return 1
    path_snapshot "$stage" "${_psiphon_install_paths[@]}" || return 1
    touched=yes
    info "Настраивается Psiphon $PSIPHON_UPSTREAM_VERSION. Ожидание туннеля может занять до двух минут."
    if ! env -u DOCKER_HOST -u DOCKER_CONTEXT -u BASH_ENV -u ENV -u NAME -u HTTP_PORT -u DEVICE_REGION \
        bash "$stage/install.sh" --region "$region" --socks-port "$port" --bind-loopback \
        --no-watchdog --no-impersonate --no-http --tunnel-pool 1 --image "$PSIPHON_IMAGE" \
        > "$stage/install.log" 2>&1; then
        tail -n 10 -- "$stage/install.log" >&2
        return 1
    fi
    _psiphon_verify "$region" "$port" "$PSIPHON_IMAGE" ||
        { fail 'Не удалось подтвердить безопасную конфигурацию SOCKS5 Psiphon.'; return 1; }
    jq -n --arg version "$PSIPHON_UPSTREAM_VERSION" --arg commit "$PSIPHON_UPSTREAM_COMMIT" \
        --arg image "$PSIPHON_IMAGE" --arg region "$region" --argjson port "$port" '{
        schema: 1, upstream: "Chara-Freedom/vps-psiphon", version: $version, commit: $commit,
        image: $image, region: $region, port: $port
    }' > "$stage/marker.json" || return 1
    chmod 0600 "$stage/marker.json" && mv -f -- "$stage/marker.json" "$(_psiphon_marker)"
)

psiphon_select_settings() {
    local region='' port=1080
    if psiphon_is_managed; then
        region=$(jq -r '.region' "$(_psiphon_marker)") || return 1
        port=$(jq -r '.port' "$(_psiphon_marker)") || return 1
    elif _psiphon_existing_install; then
        fail 'Обнаружен сторонний vps-psiphon. Используйте его существующий интерфейс.'
        return 1
    elif command -v ss >/dev/null; then
        port=$(_psiphon_default_port) || return 1
    fi
    PSIPHON_REGION=$(wizard_input 'Регион Psiphon (auto, DE, NL, US)' "${region:-auto}" _psiphon_region) || return
    # shellcheck disable=SC2034 # Read by the calling installation wizard.
    PSIPHON_PORT=$(wizard_input 'Локальный порт SOCKS5' "$port" _psiphon_input_port)
}

psiphon_apply_settings() {
    local region=$1 port=$2
    if psiphon_is_managed && jq -e --arg region "$region" --argjson port "$port" \
        --arg commit "$PSIPHON_UPSTREAM_COMMIT" --arg image "$PSIPHON_IMAGE" \
        '.region == $region and .port == $port and .commit == $commit and .image == $image' \
        "$(_psiphon_marker)" >/dev/null && [[ $(enabled "$_psiphon_service") == yes ]] &&
        _psiphon_verify "$region" "$port" "$PSIPHON_IMAGE"; then
        return 0
    fi
    _psiphon_install "$region" "$port"
}

psiphon_configure() {
    local PSIPHON_REGION PSIPHON_PORT consent
    psiphon_select_settings || return
    info "Psiphon будет доступен по TCP 127.0.0.1:$PSIPHON_PORT. HTTP-прокси отключён."
    consent=$(yes_no 'Установить или перенастроить Psiphon?' n) || return 1
    [[ $consent == yes ]] || return 0
    apt_install_missing curl python3 iproute2 || return 1
    if ! command -v docker >/dev/null; then ui_run 'Docker для Psiphon' node_prepare_docker || return 1; fi
    psiphon_apply_settings "$PSIPHON_REGION" "$PSIPHON_PORT" || return 1
    psiphon_status || return 1
    info 'Добавьте outbound в профиль Xray вручную. Для него используйте маршрутизацию TCP.'
    psiphon_outbound "$PSIPHON_PORT"
}

psiphon_update() {
    local marker region port image commit version
    if ! psiphon_is_managed; then return 0; fi
    if [[ $(active "$_psiphon_service") != yes || $(enabled "$_psiphon_service") != yes ]]; then
        info 'Psiphon остановлен или выключен из автозагрузки. Обновление пропущено.'
        return 0
    fi
    marker=$(_psiphon_marker) || return 1
    region=$(jq -r '.region' "$marker") || return 1
    port=$(jq -r '.port' "$marker") || return 1
    image=$(jq -r '.image' "$marker") || return 1
    commit=$(jq -r '.commit' "$marker") || return 1
    version=$(jq -r '.version' "$marker") || return 1
    if dpkg --compare-versions "$PSIPHON_UPSTREAM_VERSION" lt "$version"; then
        info "Установленный Psiphon $version новее проверенной версии инструмента. Обновление пропущено."
        return 0
    fi
    if [[ $commit == "$PSIPHON_UPSTREAM_COMMIT" && $image == "$PSIPHON_IMAGE" ]] &&
        _psiphon_verify "$region" "$port" "$image"; then
        info "Управляемый Psiphon $PSIPHON_UPSTREAM_VERSION уже актуален."
        return 0
    fi
    _psiphon_install "$region" "$port" || return 1
    info "Psiphon обновлён до проверенного выпуска $PSIPHON_UPSTREAM_VERSION."
}

psiphon_status() {
    local marker region port image logs count
    if ! psiphon_is_managed; then
        if _psiphon_existing_install; then
            info 'Psiphon установлен отдельно и обслуживается его собственным интерфейсом.'
        else
            info 'Psiphon не установлен.'
        fi
        return 0
    fi
    marker=$(_psiphon_marker) || return 1
    region=$(jq -r '.region' "$marker") || return 1
    port=$(jq -r '.port' "$marker") || return 1
    image=$(jq -r '.image' "$marker") || return 1
    if ! _psiphon_verify "$region" "$port" "$image"; then
        warn "Psiphon остановлен или конфигурация 127.0.0.1:$port требует проверки."
        return 1
    fi
    logs=$(_node_docker logs --tail 150 vps-psiphon 2>&1) || logs=
    count=$(jq -Rnr '[inputs | fromjson? | select(.noticeType == "Tunnels") | .data.count] | last // 0' <<< "$logs") ||
        count=0
    if [[ $count =~ ^[1-9][0-9]*$ ]]; then
        info "Psiphon работает · SOCKS5 127.0.0.1:$port · регион ${region:-auto}."
    else
        info "Psiphon запущен · SOCKS5 127.0.0.1:$port · туннель ещё не подтверждён."
    fi
}
