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
    payload=(remna-node-setup install.sh versions.json lib)
    for optional in templates docs README.md LICENSE; do
        [[ ! -e "$optional" ]] || payload+=("$optional")
    done
    if ! [[ -x remna-node-setup && -x install.sh ]]; then
        printf 'Оба скрипта должны иметь права на исполнение.\n' >&2
        exit 1
    fi
    if [[ -n "$(find "${payload[@]}" -type l -print -quit)" ]]; then
        printf 'Симлинки в архиве выпуска не поддерживаются.\n' >&2
        exit 1
    fi
    COPYFILE_DISABLE=1 tar --format=ustar --exclude='.obsidian' --exclude='.DS_Store' -czf "$staging/$archive" -- "${payload[@]}"
)
(
    cd -- "$staging"
    if command -v sha256sum >/dev/null; then
        sha256sum "$archive"
    else
        shasum -a 256 "$archive"
    fi
) > "$staging/SHA256SUMS"
mv -- "$staging/$archive" "$staging/SHA256SUMS" "$output_dir/"
printf '%s\n' "$output_dir/$archive"
