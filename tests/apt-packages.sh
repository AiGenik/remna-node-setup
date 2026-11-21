#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
log=$test_dir/apt.log
errors=$test_dir/errors
status_db=$test_dir/installed
versions_db=$test_dir/candidates
holds_db=$test_dir/holds
UPDATE_FAILURE=no
SIMULATION=ok

dpkg-query() {
    local package=${*: -1}
    [[ -f $status_db/$package ]] || return 1
    cat -- "$status_db/$package"
}

apt-mark() {
    [[ $* == showhold ]] || return 1
    cat -- "$holds_db"
}

apt-cache() {
    case "$1" in
        policy) printf '%s\n' "$2:" "  Candidate: $(cat -- "$versions_db/$2")" '  Version table:' ;;
        show)
            if [[ $2 == local-only=* ]]; then
                printf '%s\n' 'Package: local-only'
            else
                printf '%s\n' 'Filename: pool/main/test/package_1.0_all.deb'
            fi
            ;;
        *) return 1 ;;
    esac
}

apt-get() {
    local argument
    printf '%s\n' "$*" >> "$log"
    if [[ ${*: -1} == update ]]; then
        [[ $UPDATE_FAILURE == no ]] || return 100
        printf '%s\n' 'Fetched signed repository indexes'
        return 0
    fi
    [[ " $* " == *' install '* ]] || return 1
    if [[ " $* " == *' --simulate '* ]]; then
        [[ $LC_ALL == C ]] || return 1
        case $SIMULATION in
            ok)
                printf '%s\n' 'Reading package lists...' \
                    'Inst libxtables12:arm64 [1.0] (1.1 Ubuntu:24.04/noble-updates [arm64])' \
                    'Inst ufw [1:0.36-1] (1:0.37-2~ubuntu2 Ubuntu:24.04/noble-updates [all])' \
                    'Inst libxtables12:amd64 [1.0] (1.1 Ubuntu:24.04/noble-updates [amd64])' \
                    'Conf ignored-package (1.0 Ubuntu:24.04/noble-updates [all])'
                ;;
            failed)
                printf '%s\n' 'Dependency resolution failed' 'Inst ufw [1:0.36-1] (1:0.37-2~ubuntu2)'
                return 100
                ;;
            removal)
                printf '%s\n' 'Remv old-package [1.2.0]' 'Inst ufw [1:0.36-1] (1:0.37-2~ubuntu2)'
                ;;
            invalid)
                printf '%s\n' 'Inst malformed/name (1.2.0)' 'Inst ufw [1:0.36-1] (1:0.37-2~ubuntu2)'
                ;;
            incomplete) printf '%s\n' 'Inst libxtables12:arm64 (1.1)' ;;
        esac
        return 0
    fi
    for argument in "$@"; do
        case "$argument" in
            ufw=*|fail2ban=*|nginx=*|certbot=*)
                printf 'installed\t%s\n' "${argument#*=}" > "$status_db/${argument%%=*}"
                ;;
        esac
    done
}

mkdir -p -- "$status_db" "$versions_db"
printf 'installed\t%s\n' '1:0.36-1' > "$status_db/ufw"
printf 'installed\t%s\n' '2.0-1' > "$status_db/fail2ban"
printf 'installed\t%s\n' '4.0-1' > "$status_db/certbot"
printf 'installed\t%s\n' '1.0-1' > "$status_db/local-only"
printf '%s\n' '1:0.37-2~ubuntu2' > "$versions_db/ufw"
printf '%s\n' '2.1-1' > "$versions_db/fail2ban"
printf '%s\n' '3.0-1' > "$versions_db/certbot"
printf '%s\n' '1.24.0-2ubuntu7.1' > "$versions_db/nginx"
printf '%s\n' '(none)' > "$versions_db/unavailable"
printf '%s\n' '1.0-1' > "$versions_db/local-only"
printf '%s\n' 'fail2ban:all' > "$holds_db"

plan=$(apt_upgrade_installed_preview ufw fail2ban nginx certbot 2>"$errors")
[[ $plan == $'ufw\t1:0.36-1\t1:0.37-2~ubuntu2' ]]
grep -Fq 'Fetched signed repository indexes' "$errors"
grep -Fq 'fail2ban: пропущен из-за apt-mark hold.' "$errors"
grep -Fq 'certbot: установленная версия новее' "$errors"
(( $(wc -l < "$log") == 1 ))

effects=$(apt_upgrade_installed_effects "$plan")
[[ $effects == $'libxtables12\nufw' ]]
[[ $(apt_installed_version ufw) == '1:0.36-1' ]]
grep -Fq 'install -y --no-install-recommends --no-remove --only-upgrade --simulate ufw=1:0.37-2~ubuntu2' "$log"
for SIMULATION in failed removal invalid incomplete; do
    if effects=$(apt_upgrade_installed_effects "$plan" 2>"$errors"); then exit 1; fi
    [[ -z $effects && -s $errors ]]
done
SIMULATION=ok

apt_upgrade_installed_apply "$plan"
grep -Fq 'DPkg::Lock::Timeout=120' "$log"
grep -Fq 'DPkg::Options::=--force-confold' "$log"
grep -Fq 'APT::Get::allow-downgrades=false' "$log"
grep -Fq 'APT::Get::allow-change-held-packages=false' "$log"
grep -Fq 'APT::Get::allow-unauthenticated=false' "$log"
grep -Fq 'install -y --no-install-recommends --no-remove --only-upgrade ufw=1:0.37-2~ubuntu2' "$log"
[[ $(apt_installed_version ufw) == '1:0.37-2~ubuntu2' ]]
[[ -z $(apt_installed_version nginx) ]]

: > "$log"
effects=$(apt_upgrade_installed_effects "$plan")
[[ -z $effects && ! -s $log ]]
printf 'installed\t%s\n' '1:0.38-1' > "$status_db/ufw"
if apt_upgrade_installed_apply "$plan" > /dev/null 2>"$errors"; then exit 1; fi
grep -Fq 'Версия пакета ufw изменилась.' "$errors"
[[ ! -s $log ]]

apt_install_current nginx
grep -Fq 'install -y --no-install-recommends --no-remove nginx=1.24.0-2ubuntu7.1' "$log"
[[ $(apt_installed_version nginx) == '1.24.0-2ubuntu7.1' ]]

: > "$log"
if apt_install_current unavailable > /dev/null 2>"$errors"; then exit 1; fi
grep -Fq 'нет пакета unavailable.' "$errors"
(( $(wc -l < "$log") == 1 ))

: > "$log"
if apt_install_current local-only > /dev/null 2>"$errors"; then exit 1; fi
grep -Fq 'не находит эту версию в подключённых репозиториях' "$errors"
(( $(wc -l < "$log") == 1 ))

: > "$log"
if apt_install_current fail2ban > /dev/null 2>"$errors"; then exit 1; fi
grep -Fq 'fail2ban до 2.1-1 заблокированы apt-mark hold.' "$errors"
(( $(wc -l < "$log") == 1 ))

: > "$log"
UPDATE_FAILURE=yes
if apt_upgrade_installed_preview ufw > /dev/null 2>"$errors"; then exit 1; fi
grep -Fq 'Не удалось обновить индексы APT.' "$errors"
(( $(wc -l < "$log") == 1 ))

printf '%s\n' 'Выбор версий APT, режим только обновлений и проверки безопасного применения пройдены.'
