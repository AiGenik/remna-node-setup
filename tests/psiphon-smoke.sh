#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/psiphon.sh
source "$PROJECT_DIR/lib/psiphon.sh"

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
STATE_DIR=$fixture
_psiphon_environment="$fixture/vps-psiphon"

[[ $(_psiphon_region auto) == "" && $(_psiphon_region de) == DE ]]
if _psiphon_region 'DE; echo x' 2>/dev/null; then exit 1; fi
psiphon_outbound 1080 | jq -e '
    .tag == "psiphon-out" and .protocol == "socks" and
    .settings == {address:"127.0.0.1",port:1080}' >/dev/null

cat > "$fixture/upstream.sh" <<'SCRIPT'
cat <<'RUN'
rm -f "$cfg.new"
  setline DisableTactics true
exec docker run \
  "${PUB[@]}" \
  "$IMAGE"
RUN
/usr/local/sbin/$P status
SCRIPT
curl() {
    while (( $# > 1 )); do
        if [[ $1 == --output ]]; then cp -- "$fixture/upstream.sh" "$2"; return; fi
        shift
    done
    return 1
}
if _psiphon_download_installer "$fixture/downloaded.sh" 2>/dev/null; then exit 1; fi
test_hash=$(sha256sum < "$fixture/upstream.sh")
PSIPHON_INSTALLER_SHA256=${test_hash%% *}
_psiphon_download_installer "$fixture/downloaded.sh"
_psiphon_adapt_installer "$fixture/upstream.sh" "$fixture/adapted.sh"
bash -n "$fixture/adapted.sh"
grep -Fq 'setline DisableLocalHTTPProxy true' "$fixture/adapted.sh"
grep -Fq "setkey LocalSocksProxyPort \"\$SOCKS_PORT\"" "$fixture/adapted.sh"
grep -Fq 'netstat -ltn' "$fixture/adapted.sh"
external_status="/usr/local/sbin/\$P status"
if grep -Fxq "$external_status" "$fixture/adapted.sh"; then exit 1; fi
printf '%s\n' "$external_status" >> "$fixture/upstream.sh"
if _psiphon_adapt_installer "$fixture/upstream.sh" "$fixture/adapted.sh" 2>/dev/null; then exit 1; fi

_node_docker() { printf '%s\n' "$test_bindings"; }
test_bindings='{"1080/tcp":[{"HostIp":"127.0.0.1","HostPort":"1080"}]}'
_psiphon_port_bindings_ok 1080
test_bindings='{"1080/tcp":[{"HostIp":"0.0.0.0","HostPort":"1080"}]}'
if _psiphon_port_bindings_ok 1080; then exit 1; fi
test_bindings='{"1080/tcp":[{"HostIp":"127.0.0.1","HostPort":"1080"}],"8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}'
if _psiphon_port_bindings_ok 1080; then exit 1; fi

psiphon_is_managed() { [[ $test_managed == yes ]]; }
active() { printf '%s\n' "$test_running"; }
enabled() { printf '%s\n' "$test_running"; }
_psiphon_install() { printf '%s %s\n' "$1" "$2" > "$fixture/install"; }
_psiphon_verify() { return 0; }
dpkg() { return 1; }

test_managed=no test_running=yes
psiphon_update
[[ ! -e $fixture/install ]]
test_managed=yes test_running=no
psiphon_update
[[ ! -e $fixture/install ]]
test_running=yes
jq -n --arg image "$PSIPHON_IMAGE" '{
    version:"1.2",commit:"outdated",region:"DE",port:1081,image:$image
}' > "$fixture/psiphon.json"
psiphon_update
[[ $(< "$fixture/install") == 'DE 1081' ]]
rm -f -- "$fixture/install"
jq -n --arg image "$PSIPHON_IMAGE" --arg commit "$PSIPHON_UPSTREAM_COMMIT" '{
    version:"1.3",commit:$commit,region:"DE",port:1081,image:$image
}' > "$fixture/psiphon.json"
psiphon_apply_settings DE 1081
[[ ! -e $fixture/install ]]
psiphon_apply_settings NL 1081
[[ $(< "$fixture/install") == 'NL 1081' ]]

cat > "$_psiphon_environment" <<'ENV'
IMAGE=swarupsengupta2007/psiphon@sha256:ed678abc7145e0fb550eb889a5dfed74bd8495bca16b958d6b7ac582d869bfe6
BIND=127.0.0.1
SOCKS_PORT=1081
PUBLISH_HTTP=0
EGRESS_REGION=CA
ENV
[[ $(_psiphon_env_region) == CA ]]
rm -f -- "$fixture/install"
jq -n --arg image "$PSIPHON_IMAGE" '{
    version:"1.2",commit:"outdated",region:"DE",port:1081,image:$image
}' > "$fixture/psiphon.json"
psiphon_update
[[ $(< "$fixture/install") == 'CA 1081' ]]
_node_docker() { printf '{"noticeType":"Tunnels","data":{"count":1}}\n'; }
[[ $(psiphon_status 2>&1) == *'регион CA.'* ]]
printf 'EGRESS_REGION=bad\n' > "$_psiphon_environment"
if _psiphon_env_region 2>/dev/null; then exit 1; fi

curl() {
    case "$*" in
        *'/releases/latest'*)
            printf '{"tag_name":"%s"}\n' "$mock_tag"
            ;;
        *'/git/ref/tags/'*)
            printf '{"object":{"type":"commit","sha":"%s"}}\n' "$mock_commit"
            ;;
        *"/$mock_commit/psiphon_install.sh"*)
            while (( $# > 1 )); do
                if [[ $1 == --output ]]; then cp -- "$mock_script" "$2"; return 0; fi
                shift
            done
            return 1
            ;;
        *)
            while (( $# > 1 )); do
                if [[ $1 == --output ]]; then cp -- "$fixture/upstream.sh" "$2"; return 0; fi
                shift
            done
            return 1
            ;;
    esac
}
mock_tag=v1.4
mock_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mock_script="$fixture/v14.sh"
cat > "$mock_script" <<'V14_MOCK'
IMAGE=swarupsengupta2007/psiphon@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rm -f "$cfg.new"
  setline DisableTactics true
exec docker run \
  "${PUB[@]}" \
  "$IMAGE"
/usr/local/sbin/$P status
V14_MOCK
stage_v14=$(mktemp -d "$fixture/s1.XXXXXX")
resolved=$(_psiphon_prepare_source "$stage_v14")
[[ $resolved == $'1.4\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tswarupsengupta2007/psiphon@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]

mock_tag=v1.5
mock_commit=cccccccccccccccccccccccccccccccccccccccc
mock_script="$fixture/v15-broken.sh"
printf '# broken upstream missing markers\n' > "$mock_script"
stage_v15=$(mktemp -d "$fixture/s2.XXXXXX")
cp -- "$fixture/v14.sh" "$fixture/upstream.sh"
test_hash=$(sha256sum < "$fixture/upstream.sh")
PSIPHON_INSTALLER_SHA256=${test_hash%% *}
resolved=$(_psiphon_prepare_source "$stage_v15" 2>/dev/null)
[[ $resolved == "$PSIPHON_UPSTREAM_VERSION"$'\t'"$PSIPHON_UPSTREAM_COMMIT"$'\t'"$PSIPHON_IMAGE" ]]

printf '%s\n' 'psiphon-smoke OK'
