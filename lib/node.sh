#!/usr/bin/env bash

_node_project=remna-node-setup
_node_apt_key=/etc/apt/keyrings/remna-node-setup-docker.asc
_node_apt_source=/etc/apt/sources.list.d/remna-node-setup-docker.sources

_node_docker() {
    env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock "$@"
}

_node_owned_config() {
    [[ -f $NODE_DIR/compose.yaml && ! -L $NODE_DIR/compose.yaml ]] &&
        jq -e --arg name "$_node_project" '.name == $name and .services.remnanode.container_name == "remnanode"' \
            "$NODE_DIR/compose.yaml" >/dev/null 2>&1
}

_node_owns_listeners() {
    local listeners=$1 pids
    [[ -n $listeners ]] || return 1
    pids=$(_node_docker top remnanode -eo pid 2>/dev/null) || return 1
    pids=${pids//$'\n'/ }
    awk -v pids="$pids" '
        BEGIN {
            split(pids, listed, /[[:space:]]+/)
            for (i in listed)
                if (listed[i] ~ /^[0-9]+$/) owned[listed[i]] = 1
        }
        {
            seen = 0
            while (match($0, /pid=[0-9]+,/)) {
                pid = substr($0, RSTART + 4, RLENGTH - 5)
                if (!(pid in owned)) foreign = 1
                $0 = substr($0, RSTART + RLENGTH)
                seen = 1
            }
            if (!seen) foreign = 1
        }
        END { exit (NR == 0 || foreign) }
    ' <<< "$listeners"
}

node_preflight() {
    local current_port owner listeners
    if [[ -e /opt/remnanode || -L /opt/remnanode ]]; then
        fail "Найдена сторонняя нода в /opt/remnanode. См. раздел о существующей ноде в документации."
        return 1
    fi
    if [[ -L $NODE_DIR ]]; then
        fail "Путь $NODE_DIR уже используется."
        return 1
    fi
    current_port=""
    if [[ -e $NODE_DIR/compose.yaml || -L $NODE_DIR/compose.yaml ]]; then
        _node_owned_config || { fail "В $NODE_DIR найдена сторонняя конфигурация Compose."; return 1; }
        current_port=$(jq -er '.services.remnanode.environment.NODE_PORT' "$NODE_DIR/compose.yaml") || return 1
    elif [[ -d $NODE_DIR ]] && [[ -n $(find "$NODE_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        fail "Каталог $NODE_DIR занят. См. раздел о существующей ноде в документации."
        return 1
    fi
    if command -v docker >/dev/null; then
        if ! _node_docker info >/dev/null 2>&1 || ! _node_docker compose version >/dev/null 2>&1; then
            fail "Docker уже установлен. Для продолжения нужен работающий локальный Docker Engine с плагином Compose."
            return 1
        fi
        owner=$(_node_docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' remnanode 2>/dev/null) || owner=""
        if [[ -n $owner && $owner != "$_node_project" ]] ||
            { [[ -z $owner ]] && _node_docker container inspect remnanode >/dev/null 2>&1; }; then
            fail "Найден сторонний контейнер remnanode. См. раздел о существующей ноде в документации."
            return 1
        fi
    fi
    listeners=$(ss -H -ltnp "sport = :$NODE_PORT") || return 1
    if [[ -n $listeners ]] && { [[ $current_port != "$NODE_PORT" ]] || ! _node_owns_listeners "$listeners"; }; then
        fail "Порт ноды $NODE_PORT уже занят."
        return 1
    fi
    return 0
}

# APT retains the engine and its repository if a later application step fails.
node_prepare_docker() {
    local architecture key_dir fingerprint package status
    if command -v docker >/dev/null; then
        if _node_docker info >/dev/null 2>&1 && _node_docker compose version >/dev/null 2>&1; then
            return 0
        fi
        fail "Запустите локальный Docker Engine и проверьте docker compose version."
        return 1
    fi
    architecture=$(dpkg --print-architecture) || return 1
    case $architecture in
        amd64|arm64) ;;
        *) fail "Образ ноды поддерживает amd64 и arm64."; return 1 ;;
    esac
    for package in docker.io containerd runc; do
        status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null) || status=""
        if [[ $status == ii* ]]; then
            fail "Уже установлен пакет $package. Настрой совместимый Docker Engine вручную."
            return 1
        fi
    done
    apt_install_missing ca-certificates curl gpg || return 1
    install -d -m 0755 /etc/apt/keyrings || return 1
    key_dir=$(mktemp -d) || return 1
    if ! curl --fail --silent --show-error --location --max-time 30 \
        https://download.docker.com/linux/ubuntu/gpg -o "$key_dir/key.asc"; then
        rm -rf -- "$key_dir"
        return 1
    fi
    fingerprint=$(gpg --batch --homedir "$key_dir" --with-colons --show-keys "$key_dir/key.asc" 2>/dev/null |
        awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }') ||
        fingerprint=""
    if [[ $fingerprint != 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]]; then
        rm -rf -- "$key_dir"
        fail "Отпечаток ключа репозитория Docker отличается от ожидаемого."
        return 1
    fi
    if ! install -m 0644 "$key_dir/key.asc" "$_node_apt_key"; then
        rm -rf -- "$key_dir"
        return 1
    fi
    rm -rf -- "$key_dir"
    cat >"$_node_apt_source" <<EOF_APT || return 1
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $architecture
Signed-By: $_node_apt_key
EOF_APT
    chmod 0644 "$_node_apt_source" || return 1
    apt_install_current docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
        return 1
    systemctl enable --now docker.service || return 1
    _node_docker compose version >/dev/null
}

_node_compose() (
    local secret_file=$CONFIG_DIR/node.secret
    local REMNA_NODE_SECRET
    if [[ ! -s $secret_file || -L $secret_file ]] || [[ $(stat -c '%u %a' "$secret_file") != '0 600' ]]; then
        fail "Файл ключа ноды должен принадлежать root и иметь права 0600."
        return 1
    fi
    REMNA_NODE_SECRET=$(<"$secret_file")
    if [[ -z $REMNA_NODE_SECRET || $REMNA_NODE_SECRET == *$'\r'* || $REMNA_NODE_SECRET == *$'\n'* ]]; then
        fail "Ключ ноды должен быть одной непустой строкой."
        return 1
    fi
    export REMNA_NODE_SECRET
    _node_docker compose --project-name "$_node_project" --project-directory "$NODE_DIR" \
        --env-file /dev/null --file "$NODE_DIR/compose.yaml" "$@"
)

_node_render_compose() {
    local image=$1 stage
    stage=$(mktemp "$NODE_DIR/.compose.XXXXXX") || return 1
    if ! jq -n --arg name "$_node_project" --arg image "$image" --arg port "$NODE_PORT" '{
        name: $name,
        services: {
            remnanode: {
                image: $image,
                container_name: "remnanode",
                hostname: "remnanode",
                network_mode: "host",
                restart: "unless-stopped",
                environment: {
                    NODE_PORT: $port,
                    SECRET_KEY: "${REMNA_NODE_SECRET:?missing node secret}"
                },
                logging: {driver: "json-file", options: {"max-size": "10m", "max-file": "3"}}
            }
        }
    }' >"$stage" || ! mv -f -- "$stage" "$NODE_DIR/compose.yaml"; then
        rm -f -- "$stage"
        return 1
    fi
}

node_verify() {
    local port expected state listeners owner
    _node_owned_config || return 1
    port=$(jq -er '.services.remnanode.environment.NODE_PORT' "$NODE_DIR/compose.yaml") || return 1
    expected=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return 1
    read -r owner state < <(_node_docker container inspect \
        --format '{{index .Config.Labels "com.docker.compose.project"}} {{.State.Status}}' remnanode 2>/dev/null) || return 1
    [[ $owner == "$_node_project" && $state == running ]] || return 1
    [[ $(_node_docker container inspect --format '{{.Config.Image}}' remnanode 2>/dev/null) == "$expected" ]] || return 1
    listeners=$(ss -H -ltnp "sport = :$port") || return 1
    _node_owns_listeners "$listeners"
}

_node_wait_ready() {
    local attempt
    for ((attempt = 0; attempt < 25; attempt++)); do
        if node_verify; then
            return 0
        fi
        sleep 1
    done
    fail "Нода не открыла локальный порт вовремя. Проверьте пункт «Логи»."
}

node_release_image() {
    local image
    image=$(version_get node_image) || return 1
    if [[ ! $image =~ ^(docker\.io/)?remnawave/node(:[0-9]+\.[0-9]+\.[0-9]+)?@sha256:[a-f0-9]{64}$ ]]; then
        fail "В релизе не указан проверенный образ remnawave/node по SHA-256."
        return 1
    fi
    printf '%s\n' "$image"
}

node_prepare_image() {
    local image
    image=$(node_release_image) || return 1
    node_prepare_docker || return 1
    if ! _node_docker image inspect "$image" >/dev/null 2>&1; then
        _node_docker pull "$image" || return 1
    fi
}

node_apply() {
    local image
    node_preflight || return 1
    image=$(node_release_image) || return 1
    install -d -m 0700 "$NODE_DIR" || return 1
    _node_render_compose "$image" || return 1
    _node_compose config --quiet || return 1
    _node_compose up --detach --pull never --no-build remnanode || return 1
    _node_wait_ready || return 1
    info "Служебный порт ноды $NODE_PORT слушает. Проверьте подключение в панели Remnawave."
}

node_restore_runtime() {
    local owner
    if ! command -v docker >/dev/null; then
        return 0
    fi
    if _node_owned_config; then
        _node_compose up --detach --pull never --no-build remnanode || return 1
        _node_wait_ready || return 1
        return 0
    fi
    if ! owner=$(_node_docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' remnanode 2>/dev/null); then
        _node_docker info >/dev/null 2>&1 || return 1
        return 0
    fi
    if [[ $owner == "$_node_project" ]]; then
        _node_docker container rm --force remnanode >/dev/null || return 1
    fi
    return 0
}

node_status() {
    local image port existing
    if ! _node_owned_config; then
        existing=""
        if command -v docker >/dev/null; then
            existing=$(_node_docker container inspect --format '{{.State.Status}}' remnanode 2>/dev/null) ||
                existing=""
        fi
        if [[ -n $existing || -e /opt/remnanode ]]; then
            warn "Найдена сторонняя нода${existing:+ ($existing)}. См. раздел о существующей ноде в документации."
        else
            info "Управляемая нода не установлена."
        fi
        return 0
    fi
    image=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return 1
    port=$(jq -er '.services.remnanode.environment.NODE_PORT' "$NODE_DIR/compose.yaml") || return 1
    if node_verify; then
        info "Нода: работает, TCP $port, образ $image. Связь с панелью проверяется в панели."
    else
        warn "Нода: контейнер или служебный порт $port недоступен."
        return 1
    fi
}

node_logs() {
    local lines=${1:-100}
    if [[ ! $lines =~ ^[0-9]{1,4}$ ]]; then
        fail "Укажите число строк логов от 0 до 9999."
        return 1
    fi
    _node_owned_config || { fail "Управляемая нода не найдена."; return 1; }
    _node_compose logs --no-color --tail "$lines" remnanode 2>&1 |
        python3 -uc '
import sys
from pathlib import Path

secret = Path(sys.argv[1]).read_text().strip("\r\n")
for line in sys.stdin:
    sys.stdout.write(line.replace(secret, "[скрыто]") if secret else line)
' "$CONFIG_DIR/node.secret"
}
