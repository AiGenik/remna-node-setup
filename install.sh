#!/usr/bin/env bash
# Этот файл запускается как установщик и загружается менеджером для обновлений.

RELEASE_ROOT=/opt/remna-node-setup
RELEASE_COMMAND=/usr/local/bin/remna-node-setup
RELEASE_LOCK=/run/lock/remna-node-setup.lock
RELEASE_ARCHIVE=remna-node-setup.tar.gz
RELEASE_DEFAULT_REPOSITORY=AiGenik/remna-node-setup

release_error() {
    printf 'Ошибка: %s\n' "$*" >&2
    return 1
}

release_apt_is_busy() {
    local states locks
    if states=$(systemctl show -p ActiveState --value apt-daily.service apt-daily-upgrade.service 2>/dev/null) &&
        grep -Eq '^(activating|active|deactivating|reloading)$' <<< "$states"; then
        return 0
    fi
    locks=$(lslocks --noheadings --notruncate --output PATH 2>/dev/null) || return 1
    grep -Eq '^[[:space:]]*/var/(lib/(dpkg/lock(-frontend)?|apt/lists/lock)|cache/apt/archives/lock)\*?[[:space:]]*$' <<< "$locks"
}

release_wait_for_apt() {
    local deadline=$((SECONDS + 600))
    if ! release_apt_is_busy; then return 0; fi
    printf '%s\n' 'APT занят. Проверяю каждые 5 секунд, до 10 минут.' >&2
    while release_apt_is_busy; do
        if (( SECONDS >= deadline )); then
            release_error 'APT всё ещё занят. Дождитесь завершения системных обновлений и повторите установку.'
            return
        fi
        sleep 5 || return 1
    done
    printf '%s\n' 'APT свободен. Продолжаю установку.' >&2
}

release_acquire_lock() {
    if [[ ! -e "$RELEASE_LOCK" && ! -L "$RELEASE_LOCK" ]]; then
        (umask 077; set -o noclobber; : > "$RELEASE_LOCK") 2>/dev/null || :
    fi
    if ! [[ -f "$RELEASE_LOCK" && -O "$RELEASE_LOCK" && ! -L "$RELEASE_LOCK" ]]; then
        release_error "Небезопасный файл блокировки $RELEASE_LOCK."
        return 1
    fi
    exec 9<"$RELEASE_LOCK" || return 1
    if [[ "${1:-}" == wait ]]; then
        flock -x 9 || return 1
    elif ! flock -xn 9; then
        release_error 'Другая операция ещё выполняется.'
        return 1
    fi
}

release_is_repository() {
    [[ "$1" =~ ^[[:alnum:]][[:alnum:]-]*/[[:alnum:]_.-]+$ && "${1##*/}" != . && "${1##*/}" != .. ]]
}

release_is_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

release_check_inputs() {
    release_is_repository "$1" || {
        release_error 'Укажите публичный репозиторий в формате OWNER/REPO.'
        return 1
    }
    if [[ -n "$2" ]] && { [[ "$2" != v* ]] || ! release_is_version "${2#v}"; }; then
        release_error 'Укажите тег стабильного релиза в формате v1.2.3.'
        return 1
    fi
}

release_create_stage() {
    if [[ -L "$RELEASE_ROOT" || -L "$RELEASE_ROOT/releases" ]]; then
        release_error 'Каталог релизов не должен быть симлинком.'
        return 1
    fi
    install -d -m 0755 -- "$RELEASE_ROOT" "$RELEASE_ROOT/releases" || return 1
    mktemp -d "$RELEASE_ROOT/.stage.XXXXXXXX"
}

release_validate() {
    local payload=$1 expected=${2:-} version
    if ! [[ -x "$payload/remna-node-setup" && -f "$payload/install.sh" &&
            -d "$payload/lib" && -f "$payload/versions.json" ]]; then
        release_error 'В комплекте отсутствуют необходимые файлы.'
        return 1
    fi
    version=$(jq -er '.version | strings' "$payload/versions.json") || return 1
    if ! release_is_version "$version" || [[ -n "$expected" && "$version" != "$expected" ]]; then
        release_error 'Версия комплекта не совпадает с тегом релиза.'
        return 1
    fi
    "$payload/remna-node-setup" --self-test >&2 || {
        release_error 'Новый комплект не прошёл самопроверку.'
        return 1
    }
    printf '%s\n' "$version"
}

release_curl() {
    curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 "$@"
}

release_install_client() (
    local directory=$1 stage checksum filename extra
    local assets="https://github.com/$RELEASE_DEFAULT_REPOSITORY/releases/latest/download"
    mkdir -p -- "$directory" || return 1
    stage=$(mktemp -d "$directory/.remna-ssh.XXXXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT

    release_curl -o "$stage/remna-ssh" "$assets/remna-ssh" || return 1
    release_curl -o "$stage/remna-ssh.sha256" "$assets/remna-ssh.sha256" || return 1
    read -r checksum filename extra < "$stage/remna-ssh.sha256" || return 1
    if ! [[ "$checksum" =~ ^[a-f0-9]{64}$ && "$filename" == remna-ssh && -z "$extra" ]]; then
        release_error 'В релизе отсутствует корректная сумма SHA-256 для remna-ssh.'
        return 1
    fi
    (
        cd -- "$stage" || exit 1
        printf '%s  remna-ssh\n' "$checksum" > checksum
        if command -v sha256sum >/dev/null; then
            sha256sum -c checksum
        else
            shasum -a 256 -c checksum
        fi
    ) || return 1

    if [[ -d "$directory/remna-ssh" ]]; then
        release_error "Каталог $directory/remna-ssh занимает место файла помощника."
        return 1
    fi
    chmod 0755 "$stage/remna-ssh" || return 1
    mv -f -- "$stage/remna-ssh" "$directory/remna-ssh" || return 1
    printf 'Помощник установлен. Команда запуска: %s\n' "$directory/remna-ssh"
)

release_check_latest_version() {
    local candidate=$1 current version
    current=$(release_get_optional_link "$RELEASE_ROOT/current") || return 1
    [[ -n $current ]] || return 0
    version=$(jq -er '.version | strings' "$current/versions.json") || return 1
    release_is_version "$version" || return 1
    if dpkg --compare-versions "$candidate" lt "$version"; then
        release_error "В GitHub найдена версия $candidate, а установлена $version. Для возврата используйте rollback tool."
    fi
}

release_fetch() {
    local repository=$1 requested_tag=$2 stage=$3 endpoint tag digest content
    release_check_inputs "$repository" "$requested_tag" || return 1
    endpoint="https://api.github.com/repos/$repository/releases"
    if [[ -n "$requested_tag" ]]; then
        endpoint+="/tags/$requested_tag"
    else
        endpoint+=/latest
    fi

    release_curl -H 'Accept: application/vnd.github+json' -o "$stage/release.json" "$endpoint" || {
        release_error 'Не удалось получить метаданные публичного релиза GitHub.'
        return 1
    }
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | strings' "$stage/release.json") || return 1
    release_check_inputs "$repository" "$tag" || return 1
    if [[ -z "$tag" || ( -n "$requested_tag" && "$requested_tag" != "$tag" ) ]]; then
        release_error 'Ответ GitHub не соответствует запрошенному тегу.'
        return 1
    fi
    if [[ -z "$requested_tag" ]]; then release_check_latest_version "${tag#v}" || return 1; fi
    digest=$(jq -er --arg name "$RELEASE_ARCHIVE" '
        [.assets[] | select(.name == $name)] | select(length == 1)
        | .[0].digest | strings | select(test("^sha256:[0-9a-f]{64}$"))
    ' "$stage/release.json") || {
        release_error 'В релизе отсутствует архив с проверяемой суммой SHA-256.'
        return 1
    }

    release_curl -o "$stage/$RELEASE_ARCHIVE" \
        "https://github.com/$repository/releases/download/$tag/$RELEASE_ARCHIVE" || return 1
    (
        cd -- "$stage" || exit 1
        printf '%s  %s\n' "${digest#sha256:}" "$RELEASE_ARCHIVE" | sha256sum -c -
    ) || {
        release_error 'Контрольная сумма архива не совпала.'
        return 1
    }

    # Пропускаем только обычные файлы и каталоги. GNU tar также отклоняет выход через ../.
    tar --quoting-style=escape -tvzf "$stage/$RELEASE_ARCHIVE" > "$stage/files" || return 1
    if ! awk 'substr($0, 1, 1) !~ /^[-d]$/ {exit 1} END {if (NR == 0) exit 1}' "$stage/files"; then
        release_error 'В архиве есть недопустимые типы файлов.'
        return 1
    fi
    install -d -m 0755 -- "$stage/payload" || return 1
    tar --no-same-owner --no-same-permissions --keep-old-files -xzf "$stage/$RELEASE_ARCHIVE" -C "$stage/payload" || return 1
    content=$(release_validate "$stage/payload" "${tag#v}") || return 1
    printf '%s\n' "$digest" > "$stage/payload/.archive-digest" || return 1
    printf '%s\n' "$content" > "$stage/version"
}

release_prepare_local() {
    local source=$1 stage=$2 version
    local -a payload_files=(remna-node-setup install.sh versions.json lib)
    if [[ -d "$source/templates" ]]; then
        payload_files+=(templates)
    fi
    install -d -m 0755 -- "$stage/payload" || return 1
    (
        cd -- "$source" || exit 1
        if [[ -n "$(find "${payload_files[@]}" -type l -print -quit)" ]]; then
            release_error 'Симлинки в исходных файлах не поддерживаются.'
            exit 1
        fi
        cp -R -- "${payload_files[@]}" "$stage/payload/"
    ) || return 1
    version=$(release_validate "$stage/payload") || return 1
    printf '%s-local.%s\n' "$version" "${stage##*.}" > "$stage/version"
}

release_read_link() {
    local link=$1 target id
    [[ -L "$link" ]] || return 1
    target=$(readlink -- "$link") || return 1
    id=${target#"$RELEASE_ROOT/releases/"}
    if ! [[ "$target" == "$RELEASE_ROOT/releases/"* && "$id" =~ ^[0-9][0-9A-Za-z.-]+$ &&
            -d "$target" && ! -L "$target" ]]; then
        release_error "Некорректная ссылка релиза $link."
        return 1
    fi
    printf '%s\n' "$target"
}

release_get_optional_link() {
    if [[ -e "$1" || -L "$1" ]]; then
        release_read_link "$1"
    fi
}

release_set_link() (
    local link=$1 target=$2 temporary
    if [[ -z "$target" ]]; then
        rm -f -- "$link"
        return
    fi
    temporary=$(mktemp -d "$RELEASE_ROOT/.link.XXXXXXXX") || return 1
    trap 'rm -rf -- "$temporary"' EXIT
    ln -s -- "$target" "$temporary/link" || return 1
    mv -Tf -- "$temporary/link" "$link"
)

release_switch() {
    local selected=$1 current="$RELEASE_ROOT/current" previous="$RELEASE_ROOT/previous"
    local current_target previous_target command_created=no
    local command_target="$RELEASE_ROOT/current/remna-node-setup"

    current_target=$(release_get_optional_link "$current") || return 1
    previous_target=$(release_get_optional_link "$previous") || return 1
    if [[ -e "$RELEASE_COMMAND" || -L "$RELEASE_COMMAND" ]]; then
        if ! [[ -L "$RELEASE_COMMAND" && "$(readlink -- "$RELEASE_COMMAND")" == "$command_target" ]]; then
            release_error "Команда $RELEASE_COMMAND уже занята."
            return 1
        fi
    else
        ln -s -- "$command_target" "$RELEASE_COMMAND" || return 1
        command_created=yes
    fi

    if [[ "$selected" != "$current_target" ]]; then
        if ! release_set_link "$previous" "$current_target" ||
            ! release_set_link "$current" "$selected" ||
            ! "$RELEASE_COMMAND" --self-test >&2; then
            release_set_link "$current" "$current_target" &&
                release_set_link "$previous" "$previous_target" ||
                printf 'Не удалось восстановить ссылки релиза в %s.\n' "$RELEASE_ROOT" >&2
            if [[ "$command_created" == yes ]]; then
                rm -f -- "$RELEASE_COMMAND"
            fi
            release_error 'Новый выпуск не активирован.'
            return 1
        fi
    else
        "$RELEASE_COMMAND" --self-test >&2 || return 1
    fi
}

release_activate() {
    local stage=$1 id=$2 destination
    destination="$RELEASE_ROOT/releases/$id"
    if [[ -e "$destination" || -L "$destination" ]]; then
        if ! [[ -d "$destination" && ! -L "$destination" &&
                -f "$destination/.archive-digest" && -f "$stage/payload/.archive-digest" &&
                "$(<"$destination/.archive-digest")" == "$(<"$stage/payload/.archive-digest")" ]]; then
            release_error 'Установленный выпуск с таким тегом отличается от загруженного.'
            return 1
        fi
        release_validate "$destination" "$id" >/dev/null || return 1
    else
        mv -T -- "$stage/payload" "$destination" || return 1
    fi
    release_switch "$destination" || return 1
    printf 'Активная версия скрипта %s.\n' "$id"
}

release_usage() {
    cat <<'USAGE'
sudo bash install.sh
sudo bash install.sh OWNER/REPO [vX.Y.Z]
sudo ./install.sh --local
bash install.sh --client
USAGE
}

release_install_main() (
    local repository="" tag="" stage source config_dir=/etc/remna-node-setup
    local pending_repo=""
    case "${1:-}" in
        -h|--help) release_usage; return 0 ;;
        --client)
            [[ $# -eq 1 ]] || { release_usage >&2; return 2; }
            release_install_client "$HOME/.local/bin"
            return
            ;;
        --local) [[ $# -eq 1 && -f ${BASH_SOURCE[0]:-} ]] || { release_usage >&2; return 2; } ;;
        '') [[ $# -eq 0 ]] || { release_usage >&2; return 2; }; repository=$RELEASE_DEFAULT_REPOSITORY ;;
        *)
            if (( $# < 1 || $# > 2 )); then
                release_usage >&2
                return 2
            fi
            repository=$1
            tag=${2:-}
            release_check_inputs "$repository" "$tag" || return 2
            ;;
    esac

    if (( EUID != 0 )); then
        release_error 'Запустите установщик через sudo.'
        return 1
    fi
    if ! (
        # shellcheck source=/dev/null
        source /etc/os-release
        [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]]
    ); then
        release_error 'Установщик поддерживает Ubuntu 24.04.'
        return 1
    fi
    release_acquire_lock nowait || return 1
    if [[ -s /var/lib/remna-node-setup/pending ]]; then
        release_error 'Сначала подтвердите или отмените ожидающие сетевые изменения.'
        return 1
    fi
    if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
        release_wait_for_apt || return 1
        apt-get -o APT::Update::Error-Mode=any \
            -o Acquire::AllowInsecureRepositories=false \
            -o Acquire::AllowDowngradeToInsecureRepositories=false \
            -o Acquire::AllowWeakRepositories=false update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
            -o DPkg::Options::=--force-confold -o APT::Ignore-Hold=false \
            -o APT::Get::allow-unauthenticated=false -o APT::Get::force-yes=false \
            -o APT::Get::allow-downgrades=false -o APT::Get::allow-change-held-packages=false \
            install -y --no-install-recommends --no-remove jq curl ca-certificates || return 1
    fi

    stage=$(release_create_stage) || return 1
    trap 'rm -rf -- "$stage"; if [[ -n "$pending_repo" ]]; then rm -f -- "$pending_repo"; fi' EXIT
    if [[ -n "$repository" ]]; then
        release_fetch "$repository" "$tag" "$stage" || return 1
        install -d -m 0700 -- "$config_dir" || return 1
        pending_repo=$(mktemp "$config_dir/.repository.XXXXXXXX") || return 1
        printf '%s\n' "$repository" > "$pending_repo" || return 1
    else
        source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
        release_prepare_local "$source" "$stage" || return 1
    fi
    release_activate "$stage" "$(cat "$stage/version")" || return 1
    if [[ -n "$pending_repo" ]]; then
        mv -Tf -- "$pending_repo" "$config_dir/release-repository" || return 1
    fi
    printf 'Меню открывается командой sudo remna-node-setup.\n'
)

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    set -Eeuo pipefail
    umask 022
    release_install_main "$@"
    if (( $# == 0 )) && [[ -t 0 && -t 1 ]]; then exec "$RELEASE_COMMAND"; fi
fi
