#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/release.sh
source "$PROJECT_DIR/lib/release.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

CONFIG_DIR="$fixture/etc"
RELEASE_ROOT="$fixture/opt"
RELEASE_COMMAND="$fixture/active-command"
RELEASE_LOCK="$fixture/lock"
mkdir -- "$CONFIG_DIR"
printf 'example/remna-node-setup\n' > "$CONFIG_DIR/release-repository"

fixture_payload() {
    local directory=$1 version=$2
    mkdir -p -- "$directory/lib"
    printf '{"version": "%s"}\n' "$version" > "$directory/versions.json"
    cp -- "$PROJECT_DIR/install.sh" "$directory/"
    cat > "$directory/remna-node-setup" <<'PAYLOAD'
#!/usr/bin/env bash
[[ "${1:-}" == --self-test ]] || exit 2
if [[ "${0##*/}" == active-command ]]; then
    test ! -e "$(dirname "$(realpath -- "$0")")/lib/invalid-active"
fi
PAYLOAD
    chmod 0755 "$directory/remna-node-setup"
}

fixture_archive() {
    local version=$1 digest
    local payload="$fixture/remote-$version"
    fixture_payload "$payload" "$version"
    if [[ "${2:-}" == broken ]]; then
        touch "$payload/lib/invalid-active"
    fi
    tar -czf "$fixture/$RELEASE_ARCHIVE" -C "$payload" remna-node-setup install.sh lib versions.json
    digest=$(sha256sum "$fixture/$RELEASE_ARCHIVE")
    jq -n --arg tag "v$version" --arg name "$RELEASE_ARCHIVE" --arg hash "sha256:${digest%% *}" '
        {draft:false, prerelease:false, tag_name:$tag, assets:[{name:$name,digest:$hash}]}
    ' > "$fixture/release.json"
}

# Подменяем только скачивание. Проверку SHA, распаковку, активацию и откат выполняет сам установщик.
release_curl() {
    if [[ "$1" == -H ]]; then
        cp -- "$fixture/release.json" "$4"
    else
        cp -- "$fixture/${3##*/}" "$2"
    fi
}

cp -- "$PROJECT_DIR/remna-ssh" "$fixture/remna-ssh"
(cd "$fixture" && sha256sum remna-ssh > remna-ssh.sha256)
release_install_client "$fixture/client/bin"
cmp -s "$PROJECT_DIR/remna-ssh" "$fixture/client/bin/remna-ssh"
[[ -x "$fixture/client/bin/remna-ssh" ]]
printf 'повреждение\n' >> "$fixture/remna-ssh"
if release_install_client "$fixture/client/bin" >/dev/null 2>&1; then
    printf 'Повреждённый помощник принят.\n' >&2
    exit 1
fi
cmp -s "$PROJECT_DIR/remna-ssh" "$fixture/client/bin/remna-ssh"

release_acquire_lock nowait
if (exec 9<&-; release_acquire_lock nowait) 2>/dev/null; then
    printf 'Параллельная команда смогла получить блокировку.\n' >&2
    exit 1
fi
fixture_payload "$fixture/local" 0.1.0
stage=$(release_create_stage)
release_prepare_local "$fixture/local" "$stage"
release_activate "$stage" "$(<"$stage/version")"
local_target=$(readlink -- "$RELEASE_ROOT/current")

fixture_archive 0.1.1
release_update v0.1.1
remote_target=$(readlink -- "$RELEASE_ROOT/current")
[[ "$remote_target" == "$RELEASE_ROOT/releases/0.1.1" ]]
release_update
[[ "$(readlink -- "$RELEASE_ROOT/previous")" == "$local_target" ]]

fixture_archive 0.1.0
if release_update >/dev/null 2>&1; then
    printf 'Обновление latest понизило версию.\n' >&2
    exit 1
fi
[[ "$(readlink -- "$RELEASE_ROOT/current")" == "$remote_target" ]]

fixture_archive 0.1.1
printf 'повреждение\n' >> "$fixture/$RELEASE_ARCHIVE"
if release_update >/dev/null 2>&1; then
    printf 'Повреждённый архив принят.\n' >&2
    exit 1
fi
[[ "$(readlink -- "$RELEASE_ROOT/current")" == "$remote_target" ]]

fixture_archive 0.1.2 broken
if release_update v0.1.2 >/dev/null 2>&1; then
    printf 'Неисправный выпуск активирован.\n' >&2
    exit 1
fi
[[ "$(readlink -- "$RELEASE_ROOT/current")" == "$remote_target" ]]
[[ "$(readlink -- "$RELEASE_ROOT/previous")" == "$local_target" ]]

release_rollback
[[ "$(readlink -- "$RELEASE_ROOT/current")" == "$local_target" ]]
printf 'Проверки установки, обновления, блокировки и отката пройдены.\n'
