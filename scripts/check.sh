#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
shell_files=(remna-node-setup remna-ssh install.sh lib/*.sh scripts/*.sh tests/*.sh)
for file in "${shell_files[@]}"; do bash -n "$file"; done
shellcheck -x "${shell_files[@]}"
./remna-node-setup --self-test
./tests/ssh-settings.sh
./tests/selfsteal-settings.sh
./tests/standalone-settings.sh
bash tests/apt-packages.sh
bash tests/vpn-port-migration.sh
python3 tests/dns-settings.py
python3 tests/ui-smoke.py
./tests/release-smoke.sh

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
./scripts/build-release.sh "$stage"
cd -- "$stage"
sha256sum --check SHA256SUMS
sha256sum --check remna-ssh.sha256
mkdir payload
tar -xzf remna-node-setup.tar.gz -C payload
./payload/remna-node-setup --self-test
cmp -s remna-ssh payload/remna-ssh
printf '%s\n' 'Проверки и сборка релиза прошли.'
