#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/node.sh
source "$PROJECT_DIR/lib/node.sh"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
NODE_DIR=$fixture/node
NODE_PORT=2222
mkdir -- "$NODE_DIR"

amd64=$(printf 'a%.0s' {1..64})
arm64=$(printf 'b%.0s' {1..64})
jq -n --arg amd64 "sha256:$amd64" --arg arm64 "sha256:$arm64" '{
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.index.v1+json",
    manifests: [
        {platform: {os: "linux", architecture: "amd64"},
         mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $amd64},
        {platform: {os: "linux", architecture: "arm64"},
         mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $arm64}
    ]
}' > "$fixture/complete.json"
jq 'del(.manifests[1])' "$fixture/complete.json" > "$fixture/amd64.json"

manifest=$fixture/complete.json
latest='{"draft":false,"prerelease":false,"tag_name":"v9.3.4"}'
hash=$(sha256sum < "$manifest")
selected="remnawave/node:v9.3.4@sha256:${hash%% *}"

_node_metadata_get() {
    local output='' headers='' url='' auth='' sum
    while (( $# )); do
        case "$1" in
            --output) output=$2; shift ;;
            --dump-header) headers=$2; shift ;;
            --header) shift; if [[ $1 == @- ]]; then IFS= read -r auth; fi ;;
            --data-urlencode) shift ;;
            https://*) url=$1 ;;
        esac
        shift
    done
    printf '%s\n' "$url" >> "$fixture/requests"
    case "$url" in
        https://api.github.com/repos/remnawave/node/releases/latest)
            printf '%s\n' "$latest" ;;
        https://auth.docker.io/token)
            printf '%s\n' '{"token":"registry-fixture"}' ;;
        https://registry-1.docker.io/v2/remnawave/node/manifests/v9.3.4)
            [[ $auth == 'Authorization: Bearer registry-fixture' ]] || return 1
            [[ ${registry_down:-no} != yes ]] || return 22
            cp -- "$manifest" "$output"
            sum=$(sha256sum < "$manifest")
            printf 'docker-content-digest: sha256:%s\r\n' "${override_hash:-${sum%% *}}" > "$headers"
            ;;
        *) return 1 ;;
    esac
}

# Only semantic comparison needs a Linux command, which is stubbed on macOS.
dpkg() {
    [[ $1 == --compare-versions && $3 == ge ]] || return 2
    python3 - "$2" "$4" <<'PY'
import sys

def version(value):
    return tuple(map(int, value.split(".")))

sys.exit(version(sys.argv[1]) < version(sys.argv[2]))
PY
}

[[ $(node_release_image) == "$selected" ]]

latest='{"draft":false,"prerelease":true,"tag_name":"v9.3.4"}'
if node_release_image 2>/dev/null; then exit 1; fi
latest='{"draft":false,"prerelease":false,"tag_name":"v9.3.4-rc1"}'
if node_release_image 2>/dev/null; then exit 1; fi
latest='{"draft":false,"prerelease":false,"tag_name":"v9.3.4"}'

registry_down=yes
if node_release_image 2>/dev/null; then exit 1; fi
unset registry_down
override_hash=$arm64
if node_release_image 2>/dev/null; then exit 1; fi
unset override_hash
manifest=$fixture/amd64.json
if node_release_image 2>/dev/null; then exit 1; fi
manifest=$fixture/complete.json

: > "$fixture/requests"
_node_render_compose "remnawave/node:9.4.0@sha256:$arm64"
if node_release_image 2>/dev/null; then exit 1; fi
[[ $(< "$fixture/requests") == https://api.github.com/repos/remnawave/node/releases/latest ]]

previous="remnawave/node:9.2.0@sha256:$amd64"
_node_render_compose "$previous"
node_preflight() { return 0; }
node_prepare_docker() { return 0; }
_node_wait_ready() { return 0; }
_node_compose() { return 0; }
docker() { return 99; }
_node_docker() {
    if [[ $1 == image && $2 == inspect ]]; then return 1; fi
    if [[ $1 == pull && $# == 2 ]]; then printf '%s\n' "$2" >> "$fixture/pulls"; else return 1; fi
}

NODE_SELECTED_IMAGE=$(node_release_image)
: > "$fixture/requests"
node_prepare_image
node_apply ""
[[ ! -s $fixture/requests ]]
[[ $(< "$fixture/pulls") == "$selected" ]]
[[ $(jq -er '.services.remnanode.image' "$NODE_DIR/compose.yaml") == "$selected" ]]

_node_render_compose "$previous"
node_restore_runtime
[[ $(tail -n 1 "$fixture/pulls") == "$previous" && ! -s $fixture/requests ]]

printf '%s\n' 'node-image-updates OK'
