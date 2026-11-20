#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/traffic-guard.sh
source "$project/lib/traffic-guard.sh"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR="$fixture/state"
installed="$STATE_DIR/traffic-guard"
stage="$fixture/stage"
mkdir -p "$installed" "$stage"
PANEL_IPS=192.0.2.8
ADMIN_IP=198.51.100.8
ADMIN_IPS=2001:db8:1::/48

export TG_APPLY_LOG="$fixture/applied" TG_RUNNING_RULES="$fixture/running"
export TG_EXPECTED_RULES="$fixture/expected-from-asset"
tag=v0.0.6
commit=1034567890abcdef1234567890abcdef12345678
release_url=https://api.github.com/repos/dotX12/traffic-guard/releases/latest
list_api=https://api.github.com/repos/shadow-netlab/traffic-guard-lists
asset_name=traffic-guard-linux-amd64
asset_url="https://github.com/dotX12/traffic-guard/releases/download/$tag/$asset_name"
network_failure=no

cat > "$fixture/asset" <<'BINARY'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == full && $2 == --urls && $3 == https://raw.githubusercontent.com/* ]]
printf '%s\n' "$3" >> "$TG_APPLY_LOG"
cp -- "$TG_EXPECTED_RULES" "$TG_RUNNING_RULES"
BINARY

write_release() {
    local sha size
    sha=$(sha256sum -- "$fixture/asset")
    size=$(wc -c < "$fixture/asset" | tr -d '[:space:]')
    jq -n --arg tag "$tag" --arg name "$asset_name" --arg url "$asset_url" \
        --arg digest "sha256:${sha%% *}" --argjson size "$size" '
        {tag_name: $tag, draft: false, prerelease: false, assets: [
            {name: $name, state: "uploaded", browser_download_url: $url, digest: $digest, size: $size}
        ]}' > "$fixture/release-content"
}

write_list() {
    local blob size
    printf '%s\n' "$1" > "$fixture/list-content"
    cp -- "$fixture/list-content" "$TG_EXPECTED_RULES"
    raw_url="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/$commit/public/antiscanner.list"
    size=$(wc -c < "$fixture/list-content" | tr -d '[:space:]')
    blob=$( { printf 'blob %s\0' "$size"; cat "$fixture/list-content"; } | sha1sum)
    jq -n --arg commit "$commit" '[{sha: $commit}]' > "$fixture/commits-content"
    jq -n --arg url "$raw_url" --arg sha "${blob%% *}" --argjson size "$size" '
        {type: "file", path: "public/antiscanner.list", download_url: $url, size: $size, sha: $sha}
    ' > "$fixture/list-metadata"
}

# Override network and firewall operations. No host rules or installed binaries are used.
uname() { printf '%s\n' x86_64; }
security_ufw_active() { return 0; }
traffic_guard_verify() { cmp -s "$1/expected" "$TG_RUNNING_RULES"; }
traffic_guard_download() {
    case "$1" in
        "$release_url")
            [[ $network_failure == no ]] || return 1
            cp -- "$fixture/release-content" "$2" ;;
        "$list_api/commits?path=public%2Fantiscanner.list&per_page=1")
            cp -- "$fixture/commits-content" "$2" ;;
        "$list_api/contents/public/antiscanner.list?ref=$commit")
            cp -- "$fixture/list-metadata" "$2" ;;
        "$raw_url") cp -- "$fixture/list-content" "$2" ;;
        "$asset_url") cp -- "$fixture/asset" "$2" ;;
        *) printf 'Unexpected download %s\n' "$1" >&2; return 1 ;;
    esac
}

# The fixtures' semantic version comparison also works on macOS.
if ! command -v dpkg >/dev/null; then
    dpkg() {
        [[ $1 == --compare-versions && $3 == ge ]] || return 1
        python3 - "$2" "$4" <<'PY'
import sys

def version(value):
    return tuple(map(int, value.split(".")))

sys.exit(version(sys.argv[1]) < version(sys.argv[2]))
PY
    }
fi

write_release
write_list '203.0.113.0/24'
printf '%s\n' '0.0.5' > "$installed/version"
printf '%s\n' 'legacy binary' > "$installed/traffic-guard"

network_failure=yes
if traffic_guard_apply >/dev/null 2>&1; then exit 1; fi
[[ $(< "$installed/version") == 0.0.5 && $(< "$installed/traffic-guard") == 'legacy binary' ]]
[[ ! -e $TG_APPLY_LOG ]]

network_failure=no
traffic_guard_prepare "$stage"
traffic_guard_apply "$stage"
[[ $(< "$installed/version") == 0.0.6 && $(< "$installed/list-commit") == "$commit" ]]
[[ $(< "$TG_APPLY_LOG") == "$raw_url" ]]

traffic_guard_prepare "$stage"
traffic_guard_apply "$stage"
[[ $(wc -l < "$TG_APPLY_LOG") -eq 1 ]]

commit=2034567890abcdef1234567890abcdef12345678
write_list '203.0.113.128/25'
traffic_guard_prepare "$stage"
traffic_guard_apply "$stage"
[[ $(< "$installed/list-commit") == "$commit" && $(wc -l < "$TG_APPLY_LOG") -eq 2 ]]

printf '%s\n' '0.0.7' > "$installed/version"
if traffic_guard_apply "$stage" >/dev/null 2>&1; then exit 1; fi
if traffic_guard_prepare "$stage" >/dev/null 2>&1; then exit 1; fi
[[ ! -f $stage/refs && $(< "$installed/version") == 0.0.7 ]]
printf '%s\n' '0.0.6' > "$installed/version"

reject_update() {
    if traffic_guard_prepare "$stage" >/dev/null 2>&1; then exit 1; fi
    [[ ! -f $stage/refs && $(wc -l < "$TG_APPLY_LOG") -eq 2 ]]
}

printf '%s\n' '203.0.113.1/32' > "$fixture/list-content"
reject_update
write_list '192.0.2.0/24'
reject_update
write_list '2001:db8:1::/48'
reject_update
write_list '203.0.113.0/24'

jq '.prerelease = true' "$fixture/release-content" > "$fixture/corrupt"
mv -- "$fixture/corrupt" "$fixture/release-content"
reject_update
write_release
jq '.assets[0].browser_download_url = "https://example.org/traffic-guard-linux-amd64"' "$fixture/release-content" > "$fixture/corrupt"
mv -- "$fixture/corrupt" "$fixture/release-content"
reject_update
write_release
jq 'del(.assets[0].digest)' "$fixture/release-content" > "$fixture/corrupt"
mv -- "$fixture/corrupt" "$fixture/release-content"
reject_update
write_release
printf '%s\n' 'corrupt binary' > "$installed/traffic-guard"
printf '%s\n' 'invalid download' > "$fixture/asset"
reject_update
[[ $(< "$installed/traffic-guard") == 'corrupt binary' ]]

printf '%s\n' 'TrafficGuard upstream update tests passed.'
