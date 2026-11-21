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

printf '%s\n' 'psiphon-smoke OK'
