#!/usr/bin/env bash
set -euo pipefail

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/common.sh
source "$project/lib/common.sh"
# shellcheck source=lib/manager.sh
source "$project/lib/manager.sh"

SSH_CONNECTION='127.0.0.1 31938 127.0.0.1 22'
get_admin_ip
[[ -z $ADMIN_IP && $(detect_ssh_port 2202) == 2202 ]]

SSH_CONNECTION='192.0.2.10 31939 192.0.2.20 2203'
get_admin_ip
[[ $ADMIN_IP == 192.0.2.10 && $(detect_ssh_port 2202) == 2203 ]]
printf '%s\n' 'Проверен выбор SSH-порта из локальной консоли и удалённого подключения.'
