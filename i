#!/usr/bin/env bash
set -euo pipefail

# Короткая точка входа: ставит rns / remna-ssh на Mac / Linux (и запускает мастер),
# либо устанавливает Remna Node Setup напрямую на Ubuntu VPS (под root).
# Для Windows PowerShell используйте i.ps1.
REPO_URL='https://github.com/AiGenik/remna-node-setup/raw/HEAD/install.sh'

_i_ensure_path() {
    local bin_dir=$1 rc='' line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    case ":${PATH-}:" in
        *":$bin_dir:"*) return 0 ;;
    esac
    if [[ -n ${ZSH_VERSION:-} || ${SHELL:-} == *zsh || $(uname -s) == Darwin ]]; then
        rc="$HOME/.zshrc"
    elif [[ -f $HOME/.bashrc ]]; then
        rc="$HOME/.bashrc"
    else
        rc="$HOME/.profile"
    fi
    if [[ ! -f $rc ]] || ! grep -Fq '.local/bin' "$rc" 2>/dev/null; then
        printf '\n# Remna Node Setup (remna-ssh / rns)\n%s\n' "$line" >> "$rc" 2>/dev/null || :
    fi
    export PATH="$bin_dir:$PATH"
}

main() {
    local tmp mode=auto
    for arg in "$@"; do
        case "$arg" in
            --client|--panel|-p|--bootstrap) mode=client; break ;;
        esac
    done
    if [[ $mode == auto ]]; then
        if [[ $(uname -s) != Linux || ${EUID:-$(id -u)} -ne 0 ]]; then
            mode=client
        else
            mode=server
        fi
    fi

    tmp=$(mktemp)
    trap 'rm -f -- "$tmp"' EXIT
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 60 "$REPO_URL" -o "$tmp"

    if [[ $mode == client ]]; then
        bash "$tmp" --client
        _i_ensure_path "$HOME/.local/bin"
        if [[ ! -t 0 && -r /dev/tty ]]; then
            exec "$HOME/.local/bin/remna-ssh" "$@" </dev/tty
        else
            exec "$HOME/.local/bin/remna-ssh" "$@"
        fi
    else
        if [[ ! -t 0 && -r /dev/tty ]]; then
            bash "$tmp" "$@" </dev/tty
        else
            bash "$tmp" "$@"
        fi
    fi
}

main "$@"
