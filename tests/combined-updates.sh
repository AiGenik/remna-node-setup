#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/updates.sh
source "$project/lib/updates.sh"
# shellcheck source=lib/psiphon-profile.sh
source "$project/lib/psiphon-profile.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
CONFIG_DIR="$fixture/etc"
STATE_DIR="$fixture/state"
mkdir -p "$CONFIG_DIR" "$STATE_DIR/traffic-guard"
printf '%s\n' '{}' > "$CONFIG_DIR/node.json"
printf '%s\n' 0.0.5 > "$STATE_DIR/traffic-guard/version"

printf '%s\n' ':SCANNERS-BLOCK - [0:0]' '-A ufw-before-input -j SCANNERS-BLOCK' > "$fixture/before.rules"
printf '\n' >> "$fixture/before.rules"
sed '/^[[:space:]]*$/d' "$fixture/before.rules" > "$fixture/rewritten.rules"
[[ $(update_ufw_rules_fingerprint "$fixture/before.rules") == "$(update_ufw_rules_fingerprint "$fixture/rewritten.rules")" ]]
printf '%s\n' '-A ufw-before-input -p tcp --dport 22 -j DROP' >> "$fixture/rewritten.rules"
[[ $(update_ufw_rules_fingerprint "$fixture/before.rules") != "$(update_ufw_rules_fingerprint "$fixture/rewritten.rules")" ]]

trace="$fixture/trace"
simulate_dependency=no
guard_matches=no
fingerprint=before
load_config() {
    NODE_PORT=3000
    ENABLE_TRAFFIC_GUARD=yes
    ADMIN_IPS=192.0.2.7
}
get_admin_ip() { :; }
system_package_update_plan() { printf 'nginx\t1\t2\nufw\t1\t2\n'; }
apt_upgrade_installed_effects() {
    printf 'nginx\nnginx-common\n'
    if [[ $simulate_dependency == yes || $1 == *ufw* ]]; then printf 'ufw\n'; fi
}
ufw() { :; }
security_ufw_state() { printf 'active\n'; }
ui_run() { shift; "$@"; }
apply_system_package_updates() {
    if [[ $1 == *ufw* ]]; then
        printf 'packages-all\n' >> "$trace"
    else
        printf 'packages-safe\n' >> "$trace"
    fi
}
node_verify() { :; }
update_node() { printf 'node-%s\n' "$1" >> "$trace"; }
psiphon_is_managed() { :; }
psiphon_update() { printf 'psiphon\n' >> "$trace"; }
traffic_guard_prepare() { [[ -d $1 ]]; }
traffic_guard_verify() { [[ $guard_matches == yes ]]; }
traffic_guard_firewall_active() { :; }
traffic_guard_apply() { printf 'traffic-guard\n' >> "$trace"; }
update_firewall_fingerprint() { printf '%s\n' "$fingerprint"; }
run_change() {
    local scope=$1
    shift
    printf '%s\n' "$scope" >> "$trace"
    if [[ $1 == --verified-network ]]; then
        printf 'local-verification\n' >> "$trace"
        shift
    fi
    "$@"
}

apply_combined_updates manual 0 >/dev/null
diff -u <(printf '%s\n' node-if-needed psiphon network packages-all traffic-guard) "$trace"
: > "$trace"
apply_combined_updates auto 0 >/dev/null
diff -u <(printf '%s\n' packages-safe node-if-needed psiphon network local-verification traffic-guard) "$trace"

: > "$trace"
simulate_dependency=yes guard_matches=yes apply_combined_updates auto 0 >/dev/null
diff -u <(printf '%s\n' node-if-needed psiphon) "$trace"
if fingerprint=changed update_guard_verified "$STATE_DIR" before >/dev/null 2>&1; then exit 1; fi
if guard_matches=yes apply_combined_updates manual 1 >/dev/null 2>&1; then exit 1; fi

psiphon_outbound() {
    printf '%s\n' '{"tag":"psiphon-out","protocol":"socks","settings":{"address":"127.0.0.1","port":1080}}'
}
psiphon_profile '192.0.2.8' | jq -e '
    .outbounds[1].settings == {address:"127.0.0.1",port:1080} and
    .routing.rules[0].ruleTag == "youtube-direct" and .routing.rules[0].outboundTag == "DIRECT" and
    .routing.rules[1].network == "udp" and .routing.rules[1].port == "443" and
    .routing.rules[2].outboundTag == "psiphon-out" and
    all(.routing.rules[1:][]; .localIP == ["192.0.2.8/32"] and
        (.domain | index("geosite:google-gemini")) and
        (.domain | index("domain:geminiweb-pa.clients6.google.com")) and
        (.domain | index("domain:antigravity.google")) and
        ((.domain | index("full:www.google.com")) == null))
' >/dev/null
psiphon_profile 'all' | jq -e '
    .routing.rules[0].ruleTag == "youtube-direct" and
    all(.routing.rules[1:][]; (has("localIP") | not) and (.domain | index("domain:antigravity.google")))
' >/dev/null
psiphon_profile '2001:db8::8' |
    jq -e 'all(.routing.rules[1:][]; .localIP == ["2001:db8::8/128"])' >/dev/null
if psiphon_profile '192.0.2.8 192.0.2.9' >/dev/null 2>&1; then exit 1; fi
original=$(psiphon_profile '192.0.2.8' | jq '.routing.rules += [{outboundTag:"direct"}]')
merged=$(psiphon_profile_merge '192.0.2.9' <<< "$original")
jq -e '(.outbounds | length) == 3 and .routing.rules[3].outboundTag == "direct" and
    all(.routing.rules[1:3][]; .localIP == ["192.0.2.8/32","192.0.2.9/32"])' <<< "$merged" >/dev/null
merged_all=$(psiphon_profile_merge 'all' <<< "$merged")
jq -e 'all(.routing.rules[1:3][]; has("localIP") | not)' <<< "$merged_all" >/dev/null
[[ $(psiphon_profile_merge '192.0.2.9' <<< "$merged") == "$merged" ]]
bad=$(jq '.outbounds[1].settings.port = 1081' <<< "$original")
if psiphon_profile_merge '192.0.2.9' <<< "$bad" >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'Проверены одно обновление сети, автоматический режим и шаблон Gemini.'
