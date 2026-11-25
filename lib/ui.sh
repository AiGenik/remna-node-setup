#!/usr/bin/env bash

ui_init() {
    UI_INTERACTIVE=no
    UI_CLEAR=no
    UI_ACCENT=
    UI_OK=
    UI_BOLD=
    UI_MUTED=
    UI_WARN=
    UI_DANGER=
    UI_RESET=
    UI_LOGO='o-[+]-o'
    UI_VERSION=$(version_get version) || return
    if [[ -t 0 && -t 1 && -t 2 ]]; then
        UI_INTERACTIVE=yes
        if [[ -n ${TERM:-} && $TERM != dumb ]]; then
            UI_CLEAR=yes
            UI_LOGO='●─[◆]─●'
            UI_BOLD=$'\033[1m'
            UI_RESET=$'\033[0m'
            if [[ -z ${NO_COLOR+x} ]]; then
                UI_ACCENT=$'\033[1;96m'
                UI_OK=$'\033[1;92m'
                UI_MUTED=$'\033[2m'
                UI_WARN=$'\033[1;93m'
                UI_DANGER=$'\033[1;91m'
            fi
        fi
    fi
}

ui_layout() {
    local rows=24 columns=80 measured_rows measured_columns
    if [[ $UI_CLEAR == yes ]] && read -r measured_rows measured_columns < <(stty size 2>/dev/null); then
        if [[ $measured_rows =~ ^[1-9][0-9]*$ ]]; then rows=$measured_rows; fi
        if [[ $measured_columns =~ ^[1-9][0-9]*$ ]]; then columns=$measured_columns; fi
    fi
    UI_COMPACT=no
    if (( columns < 58 || rows < 24 )); then UI_COMPACT=yes; fi
    UI_COLUMNS=$columns
    UI_RULE_WIDTH=$(( columns > 62 ? 58 : columns - 4 ))
}

ui_fit() {
    local value=$1 width=$2
    if (( width < 1 )); then return 0; fi
    if (( ${#value} > width )); then value=${value:0:width-1}…; fi
    printf '%s' "$value"
}

ui_screen() {
    local title=$1 parent=${2-} line brand
    ui_layout
    if [[ $UI_CLEAR == yes ]]; then
        # Redraw the viewport and leave the SSH terminal's scrollback intact.
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
    brand="$UI_LOGO  REMNA NODE SETUP"
    if (( ${#brand} + ${#UI_VERSION} + 6 > UI_COLUMNS )); then brand='REMNA NODE SETUP'; fi
    brand=$(ui_fit "$brand" "$((UI_COLUMNS - ${#UI_VERSION} - 6))")
    printf '  %s%s%s  %sv%s%s\n' \
        "${UI_ACCENT:-$UI_BOLD}" "$brand" "$UI_RESET" "$UI_MUTED" "$UI_VERSION" "$UI_RESET"
    if (( UI_RULE_WIDTH >= 10 )); then
        printf -v line '%*s' "$UI_RULE_WIDTH" ''
        printf '  %s%s%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
    fi
    if [[ -n $title ]]; then
        if [[ -n $parent ]] && (( ${#parent} + ${#title} + 3 <= UI_RULE_WIDTH )); then
            printf '  %s%s / %s%s%s\n\n' "$UI_MUTED" "$parent" "$UI_RESET$UI_BOLD" "$title" "$UI_RESET"
        else
            printf '  %s%s%s\n\n' "$UI_BOLD" "$(ui_fit "$title" "$((UI_COLUMNS - 3))")" "$UI_RESET"
        fi
    fi
}

ui_section() {
    printf '  %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET"
}

ui_attention() {
    printf '  %s%s%s\n' "${UI_DANGER:-${UI_BOLD:-}}" "$1" "${UI_RESET:-}"
}

ui_network_confirmation() {
    local remaining mode=${1-}
    remaining=$(network_rollback_remaining) || remaining=
    ui_attention '● Сеть ждёт подтверждения SSH'
    if [[ -n ${SSH_MENU_TICKET:-} ]] && network_ssh_ticket_matches "$(pending_id)" "$SSH_MENU_TICKET"; then
        ui_attention 'Enter · проверка новым SSH'
    else
        if [[ $mode != menu ]]; then ui_attention 'Оставьте этот SSH-сеанс открытым.'; fi
        ui_attention 'В новом SSH-сеансе [6] → [3] или'
        ui_attention 'sudo remna-node-setup confirm'
    fi
    case "$remaining" in
        '') ui_attention 'Без подтверждения будет автооткат.' ;;
        0) ui_attention 'Срок истёк. Проверьте состояние сети.' ;;
        *) ui_attention "Автооткат через $((remaining / 60)) мин $((remaining % 60)) с." ;;
    esac
}

ui_progress_bar() {
    local completed=$1 current=$2 total=$3 width filled completed_bar remaining_bar
    width=$(( UI_RULE_WIDTH > 48 ? 36 : UI_RULE_WIDTH - 9 ))
    if (( width >= 4 )); then
        filled=$(( width * completed / total ))
        printf -v completed_bar '%*s' "$filled" ''
        printf -v remaining_bar '%*s' "$((width - filled))" ''
        printf '  %s%s%s%s%s  ' "${UI_ACCENT:-$UI_BOLD}" "${completed_bar// /━}" \
            "$UI_MUTED" "${remaining_bar// /─}" "$UI_RESET"
    fi
    printf '  %s%s / %s%s\n\n' "${UI_ACCENT:-$UI_BOLD}" "$current" "$total" "$UI_RESET"
}

ui_step() {
    local current=$1 total=$3
    ui_screen "$2" 'Установка'
    ui_progress_bar "$((current - 1))" "$current" "$total"
}

ui_pause() {
    if [[ $UI_INTERACTIVE != yes ]]; then return 0; fi
    printf '\n  %sEnter — %s%s ' "$UI_BOLD" "$1" "$UI_RESET" >&2
    IFS= read -r
}

ui_run() {
    local title=$1
    shift
    if [[ ${UI_CLEAR:-no} != yes ]]; then
        printf '\n  %s\n' "$title"
        "$@"
        return
    fi
    (
        local output status=0 mark='✓'
        output=$(mktemp) || return
        trap 'rm -f -- "$output"' EXIT
        printf '  %s…%s %s' "$UI_MUTED" "$UI_RESET" "$title"
        "$@" > "$output" 2>&1 || status=$?
        if (( status != 0 )); then mark='×'; fi
        printf '\r\033[K  %s%s%s %s\n' "$UI_BOLD" "$mark" "$UI_RESET" "$title"
        if (( status != 0 )); then tail -n 16 -- "$output" >&2; fi
        return "$status"
    )
}

ui_install_progress() {
    local completed=$1 failed=${2:-no} total=${#UI_INSTALL_PHASES[@]} current index mark color
    if [[ $UI_CLEAR != yes ]]; then return 0; fi
    current=$((completed < total ? completed + 1 : total))
    ui_screen "$UI_INSTALL_TITLE"
    ui_progress_bar "$completed" "$current" "$total"
    for index in "${!UI_INSTALL_PHASES[@]}"; do
        mark='○'
        color=$UI_MUTED
        if (( index < completed )); then
            mark='✓'
            color=${UI_OK:-$UI_BOLD}
        elif (( index == completed )); then
            mark='›'
            color=${UI_ACCENT:-$UI_BOLD}
            if [[ $failed == yes ]]; then mark='×'; color=${UI_WARN:-$UI_BOLD}; fi
        fi
        printf '  %s%s%s  %s\n' "$color" "$mark" "$UI_RESET" "${UI_INSTALL_PHASES[index]}"
    done
}

ui_install_phase() {
    if [[ $UI_CLEAR != yes ]]; then
        ui_run "[$((UI_PROGRESS_DONE + 1))/${#UI_INSTALL_PHASES[@]}] ${UI_INSTALL_PHASES[UI_PROGRESS_DONE]}" "$@" || return
    else
        ui_install_progress "$UI_PROGRESS_DONE"
        (
            local output status=0
            output=$(mktemp) || return
            trap 'rm -f -- "$output"' EXIT
            "$@" > "$output" 2>&1 || status=$?
            if (( status != 0 )); then
                ui_install_progress "$UI_PROGRESS_DONE" yes
                printf '\n'
                tail -n 16 -- "$output" >&2
            fi
            return "$status"
        ) || return
    fi
    UI_PROGRESS_DONE=$((UI_PROGRESS_DONE + 1))
}

ui_menu_status() (
    local page=$1 configured='Нода ещё не настроена' address mark='○'
    if [[ -s ${PENDING_FILE:-} ]]; then
        ui_network_confirmation menu
        printf '\n'
    elif [[ $page == main ]]; then
        if load_config 2>/dev/null; then
            configured='Настройки ноды сохранены'
            mark='●'
            if valid_port "$NODE_PORT"; then
                address="$NODE_PORT/tcp"
                if [[ -n $NODE_DOMAIN ]]; then address="$NODE_DOMAIN · $address"; fi
                if (( ${#address} + 11 <= UI_RULE_WIDTH )); then configured="Нода · $address"; fi
            fi
        elif [[ -s ${CONFIG_DIR:-/etc/remna-node-setup}/host.json ]]; then
            configured='Компоненты настроены · ноды пока нет'
        fi
        printf '  %s%s  %s%s\n\n' "$UI_MUTED" "$mark" "$configured" "$UI_RESET"
    fi
)

ui_menu_key() {
    printf '  %s[%s]%s %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET" "$UI_BOLD" \
        "$(ui_fit "$2" "$((UI_COLUMNS - 7))")" "$UI_RESET"
}

ui_preparation() {
    ui_screen 'Подготовка к установке'
    ui_section 'Адрес ноды'
    info '  IP VPS или домен с A-записью на IP.'
    info '  Для self-steal нужен домен.'
    info '  В Cloudflare выберите DNS only.'
    printf '\n'
    ui_section 'Панель Remnawave'
    info '  Ноды → Управление → + → адрес ноды'
    info '  Скопируйте Node Port и Secret Key.'
    printf '\n'
    ui_section 'IP панели для UFW'
    info '  Выполните на VPS панели'
    info '  curl -4fsS https://api.ipify.org'
}

select_selfsteal_server() {
    local current=$1 requested=${2:-} choice default=1
    case "$requested" in
        caddy|nginx) printf '%s\n' "$requested"; return 0 ;;
        '') ;;
        *) fail 'Укажите caddy или nginx.'; return 1 ;;
    esac
    if [[ $UI_INTERACTIVE != yes ]]; then printf '%s\n' "$current"; return 0; fi
    if [[ $current == nginx ]]; then default=2; fi
    printf '    1  Caddy  — автоматический HTTPS\n    2  Nginx  — сертификат через Certbot\n' >&2
    while choice=$(prompt '  Веб-сервер →' "$default"); do
        case "$choice" in
            1) printf 'caddy\n'; return 0 ;;
            2) printf 'nginx\n'; return 0 ;;
            *) warn 'Выберите 1 или 2.' ;;
        esac
    done
    return 1
}

MENU_ACTIONS=(
    'main|1|Только нода|install node-only'
    'main|2|Нода и компоненты · Gemini|install'
    'main|3|Порты и защита|@components'
    'main|4|Диагностика|@diagnostics'
    'main|5|Обновления|@updates'
    'main|6|Снимки и восстановление|@recovery'
    'main|7|Где взять данные для установки|guide'
    'components|1|Self-steal · Caddy или Nginx|selfsteal'
    'components|2|Входящие порты и защита SSH|security'
    'components|3|Настроить TCP (BBR и fq)|bbr'
    'components|4|TrafficGuard против сканеров|update traffic-guard'
    'components|5|Gemini · Настроить Psiphon|psiphon'
    'components|6|Gemini · Шаблон для Remnawave|psiphon profile'
    'components|7|Сменить порт VPN|vpn-port'
    'components|8|Восстановить автозапуск защиты|security boot'
    'components|9|Отключить или включить IPv6|ipv6'
    'diagnostics|1|Статус ноды и компонентов|status'
    'diagnostics|2|Проверка портов и сервисов|doctor'
    'diagnostics|3|Логи ноды|logs'
    'diagnostics|4|Проверить DNS домена|dns'
    'diagnostics|5|Проверить связь до установки|preflight'
    'recovery|1|Сохранить снимок|backup'
    'recovery|2|Восстановить снимок|restore'
    'recovery|3|Подтвердить сетевые настройки|confirm'
    'recovery|4|Откатить сетевые изменения|rollback'
    'updates|1|Обновить скрипт|update tool'
    'updates|2|Обновить ноду|update node'
    'updates|3|Откатить версию скрипта|rollback tool'
    'updates|4|Обновить системные пакеты|update packages'
    'updates|5|Обновить TrafficGuard|update traffic-guard'
    'updates|6|Обновить всё|update all'
    'updates|7|Автообновления|auto-updates'
)

ui_restart_menu() {
    if [[ -n ${SSH_PANEL_PROBE_HOST:-} ]]; then
        if "$RELEASE_COMMAND" --supports-panel-probe >/dev/null 2>&1; then
            exec "$RELEASE_COMMAND" __ssh-menu "$SSH_MENU_TICKET" - "$SSH_PANEL_PROBE_HOST"
        fi
        info 'Для автоматической проверки с панели нужен Remna Node Setup 1.1 или новее.'
        return 0
    fi
    if [[ -n ${SSH_MENU_TICKET:-} ]]; then
        if "$RELEASE_COMMAND" --supports-ssh-menu >/dev/null 2>&1; then
            exec "$RELEASE_COMMAND" __ssh-menu "$SSH_MENU_TICKET"
        fi
        info 'Выбранный выпуск открывается обычной командой sudo remna-node-setup.'
        return 0
    fi
    exec "$RELEASE_COMMAND"
}

show_menu() {
    local page=main parent title heading choice row section index label action notice=${1-} id snapshots installed_version
    local notice_color=${UI_OK:-$UI_BOLD}
    local -a command=()
    while true; do
        case "$page" in
            main) title='Главное меню' ;;
            components) title='Порты и защита' ;;
            diagnostics) title='Диагностика' ;;
            recovery) title='Снимки и восстановление' ;;
            updates) title='Обновления' ;;
        esac
        parent=
        heading=$title
        if [[ $page == main ]]; then heading=; fi
        if [[ $page != main ]]; then parent='Меню'; fi
        ui_screen "$heading" "$parent"
        ui_menu_status "$page"

        local -A labels=() actions=()
        for row in "${MENU_ACTIONS[@]}"; do
            IFS='|' read -r section index label action <<< "$row"
            [[ $section == "$page" ]] || continue
            labels[$index]=$label
            actions[$index]=$action
            if [[ $page == main ]]; then
                case "$index" in
                    1) printf '  %sУСТАНОВКА%s\n' "$UI_BOLD" "$UI_RESET" ;;
                    3)
                        if [[ $UI_COMPACT != yes ]]; then printf '\n'; fi
                        printf '  %sУПРАВЛЕНИЕ%s\n' "$UI_BOLD" "$UI_RESET"
                        ;;
                esac
            fi
            ui_menu_key "$index" "$label"
        done
        if [[ $UI_COMPACT != yes ]]; then printf '\n'; fi
        if [[ $page == main ]]; then
            printf '  %s[0] Выйти%s\n' "$UI_MUTED" "$UI_RESET"
        else
            printf '  %s[0] Назад   [q] Выйти%s\n' "$UI_MUTED" "$UI_RESET"
        fi
        if [[ -n $notice ]]; then
            printf '\n  %s%s%s\n' "$notice_color" "$(ui_fit "$notice" "$((UI_COLUMNS - 3))")" "$UI_RESET"
            notice=
        fi
        choice=$(prompt '  Номер пункта →') || return 0
        choice=${choice#"${choice%%[![:space:]]*}"}
        choice=${choice%"${choice##*[![:space:]]}"}
        if [[ $choice == [qQ] ]]; then return 0; fi
        if [[ $choice == 0 ]]; then
            if [[ $page == main ]]; then return 0; fi
            page=main
            continue
        fi
        if [[ ! $choice =~ ^[1-9]$ ]] || [[ -z ${actions[$choice]+x} ]]; then
            notice='Выберите номер из списка.'
            notice_color=${UI_WARN:-$UI_BOLD}
            continue
        fi

        action=${actions[$choice]}
        case "$action" in
            @*) page=${action#@}; continue ;;
            guide)
                ui_preparation
                ui_pause 'вернуться в меню' || return 0
                continue
                ;;
            *) ui_screen "${labels[$choice]}" "$title" ;;
        esac

        read -r -a command <<< "$action"
        if [[ $action == restore ]]; then
            snapshots=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' | sort -r) || return
            if [[ -z $snapshots ]]; then
                info '  Сначала сохраните снимок в пункте [1].'
                ui_pause 'вернуться в меню' || return 0
                continue
            fi
            printf '%s\n' "$snapshots"
            id=$(prompt '  Идентификатор снимка [0 — назад] →') || return 0
            if [[ $id == 0 ]]; then continue; fi
            command+=("$id")
        fi
        if dispatch "${command[@]}"; then
            if [[ $action == 'update tool' || $action == 'rollback tool' ]]; then
                ui_restart_menu
                return
            fi
        else
            warn 'Команда завершилась с ошибкой.'
        fi
        if [[ -n ${SSH_MENU_TICKET:-} ]] && network_ssh_ticket_matches "$(pending_id)" "$SSH_MENU_TICKET"; then
            ui_pause 'проверить SSH' || return 0
            return 42
        fi
        ui_pause 'вернуться в меню' || return 0
        if [[ $action == 'update all' && -x ${RELEASE_COMMAND:-} ]]; then
            installed_version=$("$RELEASE_COMMAND" --version) || return
            if [[ $installed_version != "$UI_VERSION" ]]; then ui_restart_menu; return; fi
        fi
    done
}
