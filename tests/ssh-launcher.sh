#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export REMNA_TEST_TRACE="$fixture/ssh"
mkdir "$fixture/bin"
cat > "$fixture/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *' ControlMaster=no '* && " $* " == *' ControlPath=none '* && " $* " == *' -p 2202 '* ]]
while (( $# > 2 )); do shift; done
[[ $1 == root@test-vps && $# == 2 ]]
printf '%s\n' "$2" | sh -n
if [[ ${REMNA_TEST_TOOL_MISSING:-} == yes ]]; then
    command=${2//\/usr\/local\/bin\/remna-node-setup/$REMNA_TEST_TRACE.missing}
    exec sh -c "$command"
fi
[[ $2 =~ __ssh-menu\ ([a-f0-9]{32})(\ ([a-f0-9]{32}))? ]]
current=${BASH_REMATCH[1]}
previous=${BASH_REMATCH[3]}
if [[ ! -f $REMNA_TEST_TRACE ]]; then
    [[ -z $previous ]]
    printf '%s\n' "$current" > "$REMNA_TEST_TRACE"
    exit 42
fi
[[ $previous == "$(< "$REMNA_TEST_TRACE")" && $current != "$previous" ]]
printf '%s\n' confirmed >> "$REMNA_TEST_TRACE"
exit "${REMNA_TEST_SSH_RESULT:-0}"
STUB
chmod +x "$fixture/bin/ssh"
export PATH="$fixture/bin:$PATH"

"$project/remna-ssh" --port 2202 root@test-vps
grep -Fxq confirmed "$REMNA_TEST_TRACE"
rm -f "$REMNA_TEST_TRACE"
result=0
REMNA_TEST_SSH_RESULT=255 "$project/remna-ssh" --port 2202 root@test-vps 2>"$fixture/error" || result=$?
[[ $result == 255 ]]
grep -Fq 'автооткат' "$fixture/error"
result=0
REMNA_TEST_TOOL_MISSING=yes "$project/remna-ssh" --port 2202 root@test-vps 2>"$fixture/error" || result=$?
[[ $result == 127 ]]
grep -Fq 'Сначала установите мастер' "$fixture/error"
if "$project/remna-ssh" --port 66000 root@test-vps 2>/dev/null; then exit 1; fi
printf '%s\n' 'Локальный SSH-запуск проверен, включая отказ повторного подключения.'
