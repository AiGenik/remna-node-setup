#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
if (( EUID != 0 )) || [[ ! -x /usr/sbin/sshd ]]; then
    printf '%s\n' 'Запустите от root на отдельной Ubuntu с установленным openssh-server.' >&2
    exit 1
fi
if [[ ! -d /run/sshd ]]; then install -d -m 0755 /run/sshd; fi
stage=$(mktemp -d /root/.remna-ssh-test.XXXXXX)
port=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)
peer=(ssh -n -F /dev/null -p "$port" -i "$stage/client" -o BatchMode=yes -o ConnectTimeout=4
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$stage/known_hosts" -o IdentitiesOnly=yes)
sshd_pid=
cleanup() {
    "${peer[@]}" -S "$stage/control" -O exit root@127.0.0.1 >/dev/null 2>&1 || :
    if [[ -n $sshd_pid ]]; then kill "$sshd_pid" 2>/dev/null || :; wait "$sshd_pid" 2>/dev/null || :; fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$stage/host"
ssh-keygen -q -t ed25519 -N '' -f "$stage/client"
printf '[127.0.0.1]:%s %s\n' "$port" "$(cut -d ' ' -f1,2 "$stage/host.pub")" > "$stage/known_hosts"
cat > "$stage/sshd.conf" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $stage/host
AuthorizedKeysFile $stage/client.pub
PidFile $stage/sshd.pid
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
CONFIG
cat > "$stage/check" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR=${0%/*}
BACKUP_DIR=$STATE_DIR/backups
CONFIG_DIR=$STATE_DIR/settings
NODE_DIR=$STATE_DIR/node
NODE_SECRET=$CONFIG_DIR/key
source "$1/lib/common.sh"
source "$1/lib/transaction.sh"
disarm_rollback() { rm -f -- "$PENDING_FILE"; }
id=20261121T120000Z-abcdef
if [[ $2 == apply ]]; then
    mkdir -p "$BACKUP_DIR/$id"
    ssh_context > "$BACKUP_DIR/$id/initiator-ssh"
    SSH_MENU_TICKET=$3
    network_mark_applied "$id"
    printf '%s\n' "$id" > "$PENDING_FILE"
else
    confirm_network "$3"
fi
FIXTURE
/usr/sbin/sshd -D -e -f "$stage/sshd.conf" > "$stage/sshd.log" 2>&1 &
sshd_pid=$!
for ((attempt=0; attempt<20; attempt++)); do
    if grep -q 'Server listening' "$stage/sshd.log"; then break; fi
    if ! kill -0 "$sshd_pid" 2>/dev/null; then cat "$stage/sshd.log" >&2; exit 1; fi
    sleep 0.1
done
"${peer[@]}" -S "$stage/control" -o ControlMaster=yes -o ControlPersist=1m -Nf root@127.0.0.1
printf -v remote 'bash %q %q' "$stage/check" "$project"
ticket=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"${peer[@]}" -o ControlPath=none root@127.0.0.1 "$remote apply $ticket"
if "${peer[@]}" -S "$stage/control" root@127.0.0.1 "$remote confirm $ticket" > "$stage/old.log" 2>&1; then exit 1; fi
grep -Fq 'открыт до применения' "$stage/old.log"
if "${peer[@]}" -o ControlPath=none root@127.0.0.1 "$remote confirm bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$stage/wrong.log" 2>&1; then exit 1; fi
grep -Fq 'другой операции' "$stage/wrong.log"
test -s "$stage/pending"
"${peer[@]}" -o ControlPath=none root@127.0.0.1 "$remote confirm $ticket"
test ! -e "$stage/pending"
printf '%s\n' 'Проверен реальный OpenSSH: старый транспорт и чужая операция отклонены.'
