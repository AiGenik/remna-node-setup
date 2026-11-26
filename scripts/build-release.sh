#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
output_dir=${1:-"$project_dir/dist"}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
archive=remna-node-setup.tar.gz
staging=$(mktemp -d "$output_dir/.package.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT

version=$(jq -er '.version | select(test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' "$project_dir/versions.json")
if [[ -n "${2:-}" && "$2" != "v$version" ]]; then
    printf 'Тег %s не совпадает с версией v%s.\n' "$2" "$version" >&2
    exit 1
fi
(
    cd -- "$project_dir"
    payload=(remna-node-setup remna-ssh remna-ssh.ps1 install.sh versions.json lib templates)
    for optional in docs README.md LICENSE SECURITY.md; do
        [[ ! -e "$optional" ]] || payload+=("$optional")
    done
    if ! [[ -x remna-node-setup && -x remna-ssh && -s remna-ssh.ps1 && -x install.sh && -s templates/index.html ]]; then
        printf 'Для выпуска нужны исполняемые скрипты, remna-ssh.ps1 и шаблон self-steal.\n' >&2
        exit 1
    fi
    if [[ -n "$(find "${payload[@]}" -type l -print -quit)" ]]; then
        printf 'Симлинки в архиве выпуска не поддерживаются.\n' >&2
        exit 1
    fi
    COPYFILE_DISABLE=1 tar --format=ustar --exclude='.obsidian' --exclude='.DS_Store' -czf "$staging/$archive" -- "${payload[@]}"
)
emit_sha256() {
    local dir=$1 file=$2
    (
        cd -- "$dir"
        if command -v sha256sum >/dev/null; then
            sha256sum "$file"
        else
            shasum -a 256 "$file"
        fi
    )
}

emit_sha256 "$staging" "$archive" > "$staging/SHA256SUMS"
install -m 0755 -- "$project_dir/remna-ssh" "$staging/remna-ssh"
install -m 0644 -- "$project_dir/remna-ssh.ps1" "$staging/remna-ssh.ps1"
emit_sha256 "$staging" remna-ssh > "$staging/remna-ssh.sha256"
emit_sha256 "$staging" remna-ssh.ps1 > "$staging/remna-ssh.ps1.sha256"
mv -- "$staging/$archive" "$staging/SHA256SUMS" "$staging/remna-ssh" "$staging/remna-ssh.sha256" "$staging/remna-ssh.ps1" "$staging/remna-ssh.ps1.sha256" "$output_dir/"
printf '%s\n' "$output_dir/$archive"
