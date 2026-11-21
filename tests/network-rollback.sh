#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
CONFIG_DIR="$fixture/config"
STATE_DIR="$fixture/state"
BACKUP_DIR="$fixture/backups"
NODE_DIR="$fixture/node"
NODE_SECRET="$CONFIG_DIR/secret"
mkdir -p -- "$STATE_DIR" "$BACKUP_DIR"

# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/security.sh
source "$project/lib/security.sh"
# shellcheck source=lib/transaction.sh
source "$project/lib/transaction.sh"

SNAPSHOT_NETWORK=()
expected_ufw_state=unknown
ufw() {
    case $expected_ufw_state in
        unknown) return 1 ;;
        malformed) printf '%s\n' 'unexpected status' ;;
        *) printf 'Status: %s\n' "$expected_ufw_state" ;;
    esac
}
active() { printf 'no\n'; }
enabled() { printf 'no\n'; }
traffic_guard_capture_runtime() { :; }
ssh_context() { printf '192.0.2.1 10100 198.51.100.1 2202\n'; }
disarm_rollback() { rm -f -- "$PENDING_FILE"; }

if capture_snapshot network; then exit 1; fi
expected_ufw_state=malformed
if capture_snapshot network; then exit 1; fi
[[ -z $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]]
expected_ufw_state=active
id=$(capture_snapshot network)
[[ $(< "$BACKUP_DIR/$id/ufw.active") == yes ]]
expected_ufw_state=inactive
inactive_id=$(capture_snapshot network)
[[ $(< "$BACKUP_DIR/$inactive_id/ufw.active") == no ]]

live="$fixture/policy"
mkdir -p -- "$fixture/restore/files$fixture" "$live"
printf 'live\n' > "$live/rule"
mkdir -- "$fixture/restore/files$live"
printf 'saved\n' > "$fixture/restore/files$live/rule"
cp() { return 1; }
if path_restore "$fixture/restore" "$live"; then exit 1; fi
[[ $(< "$live/rule") == live ]]
unset -f cp
path_restore "$fixture/restore" "$live"
[[ $(< "$live/rule") == saved ]]

IFS= read -r boot < /proc/sys/kernel/random/boot_id
printf '%s 1000\n' "$boot" > "$BACKUP_DIR/$id/network-applied"
printf '%s\n' "$id" > "$PENDING_FILE"
ssh_context() { printf '192.0.2.1 10200 198.51.100.1 2202\n'; }
expected_transport=999
ssh_transport_start() { printf '%s\n' "$expected_transport"; }
if confirm_network; then exit 1; fi
[[ -s $PENDING_FILE ]]
expected_transport=1001
confirm_network
[[ ! -e $PENDING_FILE ]]

arm_rollback() { printf '%s\n' "$1" > "$PENDING_FILE"; }
restore_snapshot() {
    if network_group_running "$(< "$fixture/worker")"; then
        printf '%s\n' 'Rollback started before mutating processes exited.' >&2
        return 1
    fi
    touch "$fixture/restored"
}
mutate() {
    printf '%s\n' "$BASHPID" > "$fixture/worker"
    (sleep 3; touch "$fixture/late-write") &
    wait
}
NETWORK_APPLY_LIMIT=1
NETWORK_RESTORE_LIMIT=5
result=0
run_change network mutate || result=$?
[[ $result == 124 && -e $fixture/restored && ! -e $fixture/late-write && ! -e $PENDING_FILE ]]

run_change network --verified-network true
[[ ! -e $PENDING_FILE ]]

printf '%s\n' 'Проверены таймер процесса, последовательность отката, состояние UFW и свежий транспорт SSH.'
