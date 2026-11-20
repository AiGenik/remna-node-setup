#!/usr/bin/env bash

# Bootstrap and the installed manager share the same release verification.
# shellcheck source=install.sh
source "$PROJECT_DIR/install.sh" || return 1

release_update() (
    local repository stage
    # CONFIG_DIR задаёт основной скрипт.
    # shellcheck disable=SC2153
    if [[ ! -f "$CONFIG_DIR/release-repository" ]]; then
        release_error 'Репозиторий не настроен. Запустите установщик с OWNER/REPO.'
        return 1
    fi
    repository=$(<"$CONFIG_DIR/release-repository")
    stage=$(release_create_stage) || return 1
    trap 'rm -rf -- "$stage"' EXIT
    release_fetch "$repository" "${1:-}" "$stage" || return 1
    release_activate "$stage" "$(cat "$stage/version")" || return 1
)

release_rollback() (
    local previous
    previous=$(release_read_link "$RELEASE_ROOT/previous") || {
        release_error 'Предыдущая версия скрипта недоступна.'
        return 1
    }
    "$previous/remna-node-setup" --self-test || {
        release_error 'Предыдущая версия скрипта не прошла самопроверку.'
        return 1
    }
    release_switch "$previous" || return 1
    printf 'Выбрана версия скрипта %s.\n' "${previous##*/}"
)
