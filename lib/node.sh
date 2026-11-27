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

_node_pinned_image_version() {
    local image=$1
    [[ $image =~ ^(docker\.io/)?remnawave/node:v?([0-9]+\.[0-9]+\.[0-9]+)@sha256:[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[2]}"
}

_node_no_downgrade() {
    local candidate=$1 current_image current_version
    if _node_owned_config; then
        current_image=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return 1
        current_version=$(_node_pinned_image_version "$current_image") ||
            { fail 'Не удалось подтвердить версию установленной ноды по Compose.'; return 1; }
        if ! dpkg --compare-versions "$candidate" ge "$current_version"; then
            fail "Релиз $candidate старше установленной версии $current_version. Понижение пропущено."
            return 1
        fi
    fi
}

_node_metadata_get() {
    curl -q --proto '=https' --fail --silent --show-error --connect-timeout 8 \
        --max-time 25 --max-filesize 2097152 "$@"
}

_node_latest_tag() {
    local release
    release=$(_node_metadata_get --header 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/remnawave/node/releases/latest) ||
        { fail 'Не удалось прочитать стабильный релиз Remnawave Node на GitHub.'; return 1; }
    jq -er '
        select(.draft == false and .prerelease == false)
        | .tag_name | strings | select(test("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    ' <<< "$release" ||
        { fail 'GitHub не вернул стабильный тег Remnawave Node.'; return 1; }
}

_node_registry_digest() (
    local tag=$1 stage token declared computed
    stage=$(mktemp -d) || return 1
    trap 'rm -rf -- "$stage"' EXIT

    token=$(_node_metadata_get --get --data-urlencode 'service=registry.docker.io' \
        --data-urlencode 'scope=repository:remnawave/node:pull' https://auth.docker.io/token |
        jq -er '.token | strings | select(test("^[A-Za-z0-9._~+/=-]+$"))') ||
        { fail 'Не удалось получить открытый доступ к образу Remnawave Node в Docker Hub.'; return 1; }
    if ! printf 'Authorization: Bearer %s\n' "$token" |
        _node_metadata_get --header @- \
            --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
            --dump-header "$stage/headers" --output "$stage/manifest" \
            "https://registry-1.docker.io/v2/remnawave/node/manifests/$tag"; then
        fail "Образ стабильного релиза $tag недоступен в Docker Hub."
        return 1
    fi
    declared=$(awk 'tolower($1) == "docker-content-digest:" { sub(/\r$/, "", $2); print $2 }' "$stage/headers") ||
        return 1
    computed=$(sha256sum < "$stage/manifest") || return 1
    if [[ ! $declared =~ ^sha256:[a-f0-9]{64}$ || $declared != "sha256:${computed%% *}" ]]; then
        fail "Контрольная сумма манифеста образа $tag не совпала."
        return 1
    fi
    if ! jq -e '
        def has_linux($arch):
            any(.manifests[];
                .platform.os == "linux" and .platform.architecture == $arch and
                (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
                 .mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
                (.digest | strings | test("^sha256:[a-f0-9]{64}$")));
        .schemaVersion == 2 and
        (.mediaType == "application/vnd.oci.image.index.v1+json" or
         .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json") and
        (.manifests | type == "array") and has_linux("amd64") and has_linux("arm64")
    ' "$stage/manifest" >/dev/null; then
        fail "Манифест образа $tag не подтверждает Linux amd64 и arm64."
        return 1
    fi
    printf '%s\n' "$declared"
)

node_release_image() {
    local tag digest
    tag=$(_node_latest_tag) || return 1
    _node_no_downgrade "${tag#v}" || return 1
    digest=$(_node_registry_digest "$tag") || return 1
    printf 'remnawave/node:%s@%s\n' "$tag" "$digest"
}

_node_ensure_image_cached() {
    local image=$1
    if ! _node_docker image inspect "$image" >/dev/null 2>&1; then
        _node_docker pull "$image" || return 1
    fi
}

node_prepare_image() {
    local image=${1:-${NODE_SELECTED_IMAGE:-}} version
    if [[ -z $image ]]; then image=$(node_release_image) || return 1; fi
    version=$(_node_pinned_image_version "$image") ||
        { fail 'Требуется стабильный образ remnawave/node с закреплённым SHA-256.'; return 1; }
    _node_no_downgrade "$version" || return 1
    node_prepare_docker || return 1
    _node_ensure_image_cached "$image"
}

node_apply() {
    local image=${1:-${NODE_SELECTED_IMAGE:-}} version
    node_preflight || return 1
    if [[ -z $image ]]; then
        image=$(node_release_image) || return 1
        node_prepare_image "$image" || return 1
    fi
    version=$(_node_pinned_image_version "$image") ||
        { fail 'Требуется стабильный образ remnawave/node с закреплённым SHA-256.'; return 1; }
    _node_no_downgrade "$version" || return 1
    install -d -m 0700 "$NODE_DIR" || return 1
    _node_render_compose "$image" || return 1
    _node_compose config --quiet || return 1
    _node_compose up --detach --pull never --no-build remnanode || return 1
    _node_wait_ready || return 1
    info "Служебный порт ноды $NODE_PORT слушает. Проверьте подключение в панели Remnawave."
}

node_runtime_state() {
    local inspection
    if ! command -v docker >/dev/null; then printf 'missing\n'; return 0; fi
    if ! inspection=$(_node_docker container inspect --format \
        '{{index .Config.Labels "com.docker.compose.project"}} {{.State.Running}}' remnanode 2>/dev/null); then
        _node_docker info >/dev/null 2>&1 || return 1
        printf 'missing\n'
        return 0
    fi
    case "$inspection" in
        "$_node_project true") printf 'running\n' ;;
        "$_node_project false") printf 'stopped\n' ;;
        *) printf 'missing\n' ;;
    esac
}

node_stop_for_network_restore() {
    local saved_compose=$1 saved_state=$2 state active_port saved_port=
    state=$(node_runtime_state) || return
    [[ $state == running ]] || return 0
    if [[ -r $saved_compose ]]; then
        saved_port=$(jq -er '.services.remnanode.environment.NODE_PORT | tostring' "$saved_compose") || saved_port=
    fi
    active_port=$(_node_docker container inspect --format '{{json .Config.Env}}' remnanode |
        jq -er 'map(select(startswith("NODE_PORT="))) | first // empty | ltrimstr("NODE_PORT=")') || active_port=
    if [[ $saved_state == running && -n $saved_port && $active_port == "$saved_port" ]]; then return 0; fi
    _node_docker container stop remnanode >/dev/null
}

node_restore_runtime() {
    local state=${1:-running} owner image
    if ! command -v docker >/dev/null; then
        return 0
    fi
    if [[ $state != missing ]] && _node_owned_config; then
        image=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return 1
        _node_pinned_image_version "$image" >/dev/null ||
            { fail 'В снимке отсутствует закреплённый образ Remnawave Node.'; return 1; }
        _node_ensure_image_cached "$image" || return 1
        if [[ $state == stopped ]]; then
            _node_compose stop remnanode || return
            _node_compose create --pull never --no-build remnanode
            return
        fi
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

_node_compose_paths() {
    local candidate
    for candidate in /opt/remnanode/docker-compose.yml /opt/remnanode/docker-compose.yaml \
        /opt/remnanode/compose.yaml /opt/remnanode/compose.yml; do
        if [[ -f $candidate && ! -L $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

_node_external_compose_parse() {
    local compose_file=$1
    [[ -r $compose_file ]] || return 1
    python3 - "$compose_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
image = ""
port = ""

m_img = re.search(r"(?m)^[ \t]*image:[ \t]*['\"]?([^\s'\"#]+)", text)
if m_img:
    image = m_img.group(1).strip()

for pat in (
    r"(?m)^[ \t]*-?[ \t]*['\"]?NODE_PORT[ \t]*[=:][ \t]*['\"]?([0-9]{1,5})",
    r"(?m)^[ \t]*-[ \t]*['\"]?[0-9.:]*:([0-9]{1,5}):[0-9]{1,5}",
):
    m_port = re.search(pat, text)
    if m_port:
        port = m_port.group(1).strip()
        break

if not port:
    env_file = path.parent / ".env"
    if env_file.is_file():
        env_text = env_file.read_text(encoding="utf-8", errors="replace")
        m_env = re.search(r"(?m)^[ \t]*NODE_PORT=([0-9]{1,5})\b", env_text)
        if m_env:
            port = m_env.group(1).strip()

print(f"{image}\t{port}")
PY
}

_node_external_inspect() {
    _NODE_EXT_STATUS=
    _NODE_EXT_IMAGE=
    _NODE_EXT_VERSION=
    _NODE_EXT_PORT=
    _NODE_EXT_COMPOSE=
    _NODE_EXT_DIR=

    local meta status='' cfg_files='' image='' port='' parsed='' parsed_img='' parsed_port=''
    if command -v docker >/dev/null 2>&1; then
        meta=$(_node_docker container inspect --format \
            '{{.State.Status}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.config_files"}}{{"\t"}}{{.Config.Image}}{{"\n"}}{{range .Config.Env}}{{println .}}{{end}}' \
            remnanode 2>/dev/null) || meta=''
        if [[ -n $meta ]]; then
            local line
            line=${meta%%$'\n'*}
            IFS=$'\t' read -r status cfg_files image <<< "$line"
            port=$(awk -F= '$1 == "NODE_PORT" {print $2; exit}' <<< "$meta") || port=
            if [[ -n $image ]]; then
                _NODE_EXT_VERSION=$(_node_pinned_image_version "$image" 2>/dev/null || :)
                if [[ -z $_NODE_EXT_VERSION ]]; then
                    _NODE_EXT_VERSION=$(_node_docker image inspect --format \
                        '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image" 2>/dev/null || :)
                    _NODE_EXT_VERSION=${_NODE_EXT_VERSION#v}
                    [[ $_NODE_EXT_VERSION != '<no value>' ]] || _NODE_EXT_VERSION=
                fi
                if [[ -z $_NODE_EXT_VERSION && $image == *:* ]]; then
                    local tag=${image##*:}
                    tag=${tag%%@*}
                    if [[ $tag != latest && -n $tag ]]; then _NODE_EXT_VERSION=${tag#v}; fi
                fi
            fi
        fi
    fi

    if [[ -n $cfg_files && -f ${cfg_files%%,*} ]]; then
        _NODE_EXT_COMPOSE=${cfg_files%%,*}
    else
        _NODE_EXT_COMPOSE=$(_node_compose_paths 2>/dev/null || :)
    fi
    if [[ -n $_NODE_EXT_COMPOSE ]]; then
        _NODE_EXT_DIR=${_NODE_EXT_COMPOSE%/*}
        if [[ -z $image || -z $port ]]; then
            parsed=$(_node_external_compose_parse "$_NODE_EXT_COMPOSE" 2>/dev/null || :)
            IFS=$'\t' read -r parsed_img parsed_port <<< "$parsed"
            [[ -n $image ]] || image=$parsed_img
            [[ -n $port ]] || port=$parsed_port
        fi
        if [[ -z $_NODE_EXT_VERSION && -n $image ]]; then
            _NODE_EXT_VERSION=$(_node_pinned_image_version "$image" 2>/dev/null || :)
            if [[ -z $_NODE_EXT_VERSION && $image == *:* ]]; then
                local ftag=${image##*:}
                ftag=${ftag%%@*}
                if [[ $ftag != latest && -n $ftag ]]; then _NODE_EXT_VERSION=${ftag#v}; fi
            fi
        fi
    fi

    _NODE_EXT_STATUS=$status
    _NODE_EXT_IMAGE=$image
    _NODE_EXT_PORT=$port
    [[ -n $status || -n $_NODE_EXT_COMPOSE || -e /opt/remnanode ]]
}

node_external_verify() {
    local listeners
    _node_external_inspect || return 1
    [[ $_NODE_EXT_STATUS == running ]] && valid_port "${_NODE_EXT_PORT:-}" || return 1
    listeners=$(ss -H -ltnp "sport = :$_NODE_EXT_PORT" 2>/dev/null) || return 1
    _node_owns_listeners "$listeners"
}

node_any_verify() {
    if _node_owned_config; then
        node_verify
    else
        node_external_verify
    fi
}

node_status() {
    local image version port
    if ! _node_owned_config; then
        if _node_external_inspect; then
            local loc=${_NODE_EXT_DIR:-/opt/remnanode}
            if node_external_verify; then
                info "Нода (внешняя, $loc)${_NODE_EXT_VERSION:+ · $_NODE_EXT_VERSION}${_NODE_EXT_PORT:+ · TCP $_NODE_EXT_PORT} · работает."
                return 0
            fi
            warn "Нода (внешняя, $loc): контейнер ${_NODE_EXT_STATUS:-не запущен}${_NODE_EXT_PORT:+ или порт $_NODE_EXT_PORT недоступен}."
            return 1
        fi
        info "Управляемая нода не установлена."
        if [[ ${1-} == required ]]; then return 1; fi
        return 0
    fi
    image=$(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") || return 1
    version=$(_node_pinned_image_version "$image") || version='неизвестная версия'
    port=$(jq -er '.services.remnanode.environment.NODE_PORT' "$NODE_DIR/compose.yaml") || return 1
    if node_verify; then
        info "Нода $version · TCP $port · работает."
    else
        warn "Нода: контейнер или служебный порт $port недоступен."
        return 1
    fi
}

_node_filter_secret_stream() {
    local secret=${1:-}
    python3 -uc '
import sys

secret = sys.argv[1]
for line in sys.stdin:
    sys.stdout.write(line.replace(secret, "[скрыто]") if secret else line)
' "$secret"
}

node_logs() {
    local lines=${1:-100}
    if [[ ! $lines =~ ^[0-9]{1,4}$ ]]; then
        fail "Укажите число строк логов от 0 до 9999."
        return 1
    fi
    if _node_owned_config; then
        local secret=''
        if [[ -s $CONFIG_DIR/node.secret ]]; then
            secret=$(<"$CONFIG_DIR/node.secret") || secret=''
            secret=${secret%$'\r'}
            secret=${secret%$'\n'}
        fi
        _node_compose logs --no-color --tail "$lines" remnanode 2>&1 |
            _node_filter_secret_stream "$secret"
        return
    fi
    if command -v docker >/dev/null 2>&1 && _node_docker container inspect remnanode >/dev/null 2>&1; then
        local ext_secret=''
        ext_secret=$(_node_docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' remnanode 2>/dev/null |
            awk -F= '$1 == "SECRET_KEY" { sub(/^[^=]*=/, ""); print; exit }') || ext_secret=''
        _node_docker logs --tail "$lines" remnanode 2>&1 |
            _node_filter_secret_stream "$ext_secret"
        return
    fi
    fail "Управляемая нода не найдена."
    return 1
}
