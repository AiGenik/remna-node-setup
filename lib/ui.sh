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
    UI_LOGO='[o]'
    UI_EYE_FRAME='╭─[  ◉  ]─╮'
    UI_INTRO_SHOWN=no
    UI_VERSION=$(version_get version) || return
    if [[ -t 0 && -t 1 && -t 2 ]]; then
        UI_INTERACTIVE=yes
        if [[ -n ${TERM:-} && $TERM != dumb ]]; then
            UI_CLEAR=yes
            UI_LOGO='╭─[ ◉ ]─╮'
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

_ui_render_header_box() {
    local eye=$1 title=$2 parent=${3-} line inner_width title_text padding left_pad
    if [[ $UI_CLEAR == yes && $UI_COMPACT != yes ]] && (( UI_RULE_WIDTH >= 42 )); then
        inner_width=$((UI_RULE_WIDTH - 2))
        printf -v line '%*s' "$inner_width" ''
        title_text="REMNA NODE SETUP"
        padding=$((inner_width - ${#eye} - ${#title_text} - ${#UI_VERSION} - 5))
        if (( padding < 1 )); then padding=1; fi
        printf -v left_pad '%*s' "$padding" ''
        printf '  %s╭%s╮%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
        printf '  %s│%s %s%s%s  %s%s%s%s%sv%s%s %s│%s\n' \
            "$UI_MUTED" "$UI_RESET" \
            "${UI_ACCENT:-$UI_BOLD}" "$eye" "$UI_RESET" \
            "$UI_BOLD" "$title_text" "$UI_RESET" "$left_pad" \
            "$UI_MUTED" "$UI_VERSION" "$UI_RESET" \
            "$UI_MUTED" "$UI_RESET"
        printf '  %s╰%s╯%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
    else
        local brand
        brand="$UI_LOGO  REMNA NODE SETUP"
        if (( ${#brand} + ${#UI_VERSION} + 6 > UI_COLUMNS )); then brand='REMNA NODE SETUP'; fi
        brand=$(ui_fit "$brand" "$((UI_COLUMNS - ${#UI_VERSION} - 6))")
        printf '  %s%s%s  %sv%s%s\n' \
            "${UI_ACCENT:-$UI_BOLD}" "$brand" "$UI_RESET" "$UI_MUTED" "$UI_VERSION" "$UI_RESET"
        if (( UI_RULE_WIDTH >= 10 )); then
            printf -v line '%*s' "$UI_RULE_WIDTH" ''
            printf '  %s%s%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
        fi
    fi
    if [[ -n $title ]]; then
        if [[ -n $parent ]] && (( ${#parent} + ${#title} + 3 <= UI_RULE_WIDTH )); then
            printf '  %s%s / %s%s%s\n\n' "$UI_MUTED" "$parent" "$UI_RESET$UI_BOLD" "$title" "$UI_RESET"
        else
            printf '  %s%s%s\n\n' "$UI_BOLD" "$(ui_fit "$title" "$((UI_COLUMNS - 3))")" "$UI_RESET"
        fi
    fi
}

_ui_eye_intro() {
    local frame
    if [[ $UI_CLEAR != yes || $UI_COMPACT == yes || $UI_INTRO_SHOWN == yes || ${UI_NO_ANIMATION:-no} == yes ]]; then
        return 0
    fi
    UI_INTRO_SHOWN=yes
    for frame in '╭─[ ◉   ]─╮' '╭─[   ◉ ]─╮' '╭─[ ─── ]─╮' '╭─[  ◉  ]─╮'; do
        printf '\033[H'
        _ui_render_header_box "$frame" '' ''
        sleep 0.09
    done
}

ui_screen() {
    local title=${1-} parent=${2-}
    ui_layout
    if [[ $UI_CLEAR == yes ]]; then
        # Redraw the viewport and leave the SSH terminal's scrollback intact.
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
    _ui_render_header_box "$UI_EYE_FRAME" "$title" "$parent"
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
    local page=$1 configured='Нода ещё не настроена' address mark='○' color=$UI_MUTED badges=''
    if [[ -s ${PENDING_FILE:-} ]]; then
        ui_network_confirmation menu
        printf '\n'
    elif [[ $page == main ]]; then
        if load_config 2>/dev/null; then
            configured='Настройки ноды сохранены'
            mark='●'
            color=${UI_OK:-$UI_BOLD}
            if valid_port "$NODE_PORT"; then
                address="$NODE_PORT/tcp"
                if [[ -n $NODE_DOMAIN ]]; then address="$NODE_DOMAIN · $address"; fi
                if (( ${#address} + 11 <= UI_RULE_WIDTH )); then configured="Нода · $address"; fi
            fi
            if [[ $UI_COMPACT != yes ]]; then
                if [[ ${ENABLE_SECURITY:-no} == yes ]]; then badges+='UFW '; else badges+='UFW(выкл) '; fi
                if [[ ${ENABLE_TRAFFIC_GUARD:-no} == yes ]]; then badges+='· TG '; fi
                if declare -F psiphon_is_managed >/dev/null && psiphon_is_managed; then
                    badges+='· Psiphon '
                fi
                if [[ ${DISABLE_IPV6:-no} == yes ]]; then badges+='· IPv4-only'; fi
            fi
        elif [[ -s ${CONFIG_DIR:-/etc/remna-node-setup}/host.json ]]; then
            configured='Компоненты настроены · ноды пока нет'
        fi
        printf '  %s%s%s  %s%s%s\n' "$color" "$mark" "$UI_RESET" "$UI_BOLD" "$configured" "$UI_RESET"
        if [[ -n $badges ]]; then
            printf '     %s%s%s\n\n' "$UI_MUTED" "$(ui_fit "$badges" "$((UI_COLUMNS - 6))")" "$UI_RESET"
        else
            printf '\n'
        fi
    fi
)

ui_menu_key() {
    printf '  %s[%2s]%s %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET" "$UI_BOLD" \
        "$(ui_fit "$2" "$((UI_COLUMNS - 8))")" "$UI_RESET"
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
        nginx|caddy) printf '%s\n' "$requested"; return 0 ;;
        '') ;;
        *) fail 'Укажите nginx или caddy.'; return 1 ;;
    esac
    if [[ $UI_INTERACTIVE != yes ]]; then printf '%s\n' "${current:-nginx}"; return 0; fi
    if [[ $current == caddy ]]; then default=2; fi
    printf '    1  Nginx  — сертификат Certbot + изоляция IP (рекомендуется)\n    2  Caddy  — автоматический HTTPS\n' >&2
    while choice=$(prompt '  Веб-сервер →' "$default"); do
        case "$choice" in
            1) printf 'nginx\n'; return 0 ;;
            2) printf 'caddy\n'; return 0 ;;
            *) warn 'Выберите 1 или 2.' ;;
        esac
    done
    return 1
}

MENU_ACTIONS=(
    'main|1|Всё под ключ · полная установка ноды|install'
    'main|2|Установка и настройка по частям|@components'
    'main|3|Проверка и аудит работы ноды|@diagnostics'
    'main|4|Проверка связи от панели к ноде|preflight'
    'main|5|Обновления и актуальные версии|@updates'
    'main|6|Снимки, подтверждение SSH и откат|@recovery'
    'main|7|Где взять данные для установки|guide'
    'components|1|Установить только ноду (без защиты)|install node-only'
    'components|2|Self-steal · Nginx или Caddy (HTTPS)|selfsteal'
    'components|3|Порты, UFW и защита SSH (Fail2Ban)|security'
    'components|4|Сменить порт VPN (например 443)|vpn-port'
    'components|5|Ускорение TCP (BBR и очередь fq)|bbr'
    'components|6|Отключить или включить IPv6|ipv6'
    'components|7|TrafficGuard (защита от сканеров)|update traffic-guard'
    'components|8|Psiphon для Gemini (локальный SOCKS5)|psiphon'
    'components|9|Шаблон Gemini для Remnawave (профиль)|psiphon profile'
    'components|10|Восстановить автозапуск защиты (UFW/TG)|security boot'
    'diagnostics|1|Статус ноды и компонентов|status'
    'diagnostics|2|Проверка портов, служб и автозапуска|doctor'
    'diagnostics|3|Живой тест: Gemini, YouTube и Certbot|audit'
    'diagnostics|4|Проверить DNS домена|dns'
    'diagnostics|5|Логи ноды|logs'
    'recovery|1|Сохранить снимок настроек|backup'
    'recovery|2|Восстановить снимок|restore'
    'recovery|3|Подтвердить сетевые настройки (SSH)|confirm'
    'recovery|4|Откатить сетевые изменения|rollback'
    'updates|1|Актуальные версии (установлено / онлайн)|versions'
    'updates|2|Обновить всё (скрипт + нода + базы + пакеты)|update all'
    'updates|3|Обновить ноду Remnawave (Xray/VLESS)|update node'
    'updates|4|Обновить Psiphon (vps-psiphon)|update psiphon'
    'updates|5|Обновить TrafficGuard и список сканеров|update traffic-guard'
    'updates|6|Обновить системные пакеты (Nginx, Certbot...)|update packages'
    'updates|7|Обновить скрипт (remna-node-setup)|update tool'
    'updates|8|Откатить версию скрипта|rollback tool'
    'updates|9|Ночные автообновления (04:00)|auto-updates'
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
            components) title='Установка и настройка по частям' ;;
            diagnostics) title='Проверка и аудит работы ноды' ;;
            recovery) title='Снимки, подтверждение и откат' ;;
            updates) title='Обновления и актуальные версии' ;;
        esac
        parent=
        heading=$title
        if [[ $page == main ]]; then heading=; fi
        if [[ $page != main ]]; then parent='Меню'; fi
        ui_screen "$heading" "$parent"
        if [[ $page == main ]]; then _ui_eye_intro; fi
        ui_menu_status "$page"

        local -A labels=() actions=()
        for row in "${MENU_ACTIONS[@]}"; do
            IFS='|' read -r section index label action <<< "$row"
            [[ $section == "$page" ]] || continue
            labels[$index]=$label
            actions[$index]=$action
            if [[ $page == main ]]; then
                case "$index" in
                    1) printf '  %sУСТАНОВКА И НАСТРОЙКА%s\n' "$UI_BOLD" "$UI_RESET" ;;
                    3)
                        if [[ $UI_COMPACT != yes ]]; then
                            printf '\n  %sПРОВЕРКА И СЕТЬ%s\n' "$UI_BOLD" "$UI_RESET"
                        fi
                        ;;
                    5)
                        if [[ $UI_COMPACT != yes ]]; then
                            printf '\n  %sОБСЛУЖИВАНИЕ%s\n' "$UI_BOLD" "$UI_RESET"
                        fi
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
        if [[ ! $choice =~ ^[1-9][0-9]*$ ]] || [[ -z ${actions[$choice]+x} ]]; then
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
