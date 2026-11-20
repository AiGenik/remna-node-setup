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
    UI_VERSION=$(version_get version) || return
    if [[ -t 0 && -t 1 && -t 2 ]]; then
        UI_INTERACTIVE=yes
        if [[ -n ${TERM:-} && $TERM != dumb ]]; then
            UI_CLEAR=yes
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
    UI_RULE_WIDTH=$(( columns > 62 ? 58 : columns - 4 ))
}

ui_screen() {
    local title=$1 parent=${2-} line
    ui_layout
    if [[ $UI_CLEAR == yes ]]; then
        # Redraw the viewport and leave the SSH terminal's scrollback intact.
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
    printf '  %s◆─●  REMNA NODE SETUP%s  %sv%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$UI_RESET" "$UI_MUTED" "$UI_VERSION" "$UI_RESET"
    if (( UI_RULE_WIDTH >= 10 )); then
        printf -v line '%*s' "$UI_RULE_WIDTH" ''
        printf '  %s%s%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
    fi
    if [[ -n $title ]]; then
        if [[ -n $parent ]] && (( ${#parent} + ${#title} + 3 <= UI_RULE_WIDTH )); then
            printf '  %s%s / %s%s%s\n\n' "$UI_MUTED" "$parent" "$UI_RESET$UI_BOLD" "$title" "$UI_RESET"
        else
            printf '  %s%s%s\n\n' "$UI_BOLD" "$title" "$UI_RESET"
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
    local remaining
    remaining=$(network_rollback_remaining) || remaining=
    ui_attention '● Сеть ждёт подтверждения SSH'
    ui_attention 'Оставьте этот сеанс открытым. Подключитесь по SSH в новом.'
    ui_attention 'Выполните sudo remna-node-setup confirm или [6] → [3].'
    case "$remaining" in
        '') ui_attention 'Без подтверждения настройки откатятся автоматически.' ;;
        0) ui_attention 'Срок подтверждения истёк. Проверьте состояние сети.' ;;
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
    if [[ $page == main ]]; then
        if load_config 2>/dev/null; then
            configured='Настройки ноды сохранены'
            mark='●'
            if valid_port "$NODE_PORT"; then
                address="$NODE_DOMAIN · $NODE_PORT/tcp"
                if (( ${#address} + 11 <= UI_RULE_WIDTH )); then configured="Нода · $address"; fi
            fi
        elif [[ -s ${CONFIG_DIR:-/etc/remna-node-setup}/host.json ]]; then
            configured='Компоненты настроены · ноды пока нет'
        fi
        printf '  %s%s  %s%s\n' "$UI_MUTED" "$mark" "$configured" "$UI_RESET"
    fi
    if [[ -s ${PENDING_FILE:-} ]]; then
        ui_network_confirmation
    fi
    if [[ $page == main || -s ${PENDING_FILE:-} ]]; then printf '\n'; fi
)

ui_menu_key() {
    printf '  %s[%s]%s %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET" "$UI_BOLD" "$2" "$UI_RESET"
}

ui_preparation() {
    ui_screen 'Подготовка к установке'
    ui_section 'DNS'
    info '  A-запись node.example.com → публичный IPv4 VPS.'
    info '  Для self-steal в Cloudflare выберите DNS only.'
    printf '\n'
    ui_section 'Панель Remnawave'
    info '  Ноды → Управление → +'
    info '  Укажите домен или IP ноды. Скопируйте Node Port и Secret Key.'
    printf '\n'
    ui_section 'IP панели'
    info '  Выполните на сервере панели'
    info '  curl -4fsS https://api.ipify.org && echo'
    printf '\n'
    info '  Оставьте открытым текущее SSH-подключение к новому VPS.'
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
    'main|1|Только нода|Docker и подключение к панели|install node-only'
    'main|2|Нода и компоненты|Self-steal, BBR и защита|install'
    'main|3|Порты и защита||@components'
    'main|4|Диагностика||@diagnostics'
    'main|5|Обновления||@updates'
    'main|6|Снимки и восстановление||@recovery'
    'main|7|Где взять данные для установки||guide'
    'components|1|Настроить self-steal|Caddy или Nginx|selfsteal'
    'components|2|Входящие порты|Правила UFW и защита SSH через Fail2Ban|security'
    'components|3|Включить BBR и fq|Настройки TCP, если их поддерживает ядро|bbr'
    'components|4|TrafficGuard|Включить или обновить список сканеров|update traffic-guard'
    'diagnostics|1|Статус|Нода и установленные компоненты|status'
    'diagnostics|2|Проверить сервисы|Порты, компоненты и место на диске|doctor'
    'diagnostics|3|Логи ноды|Последние сообщения контейнера|logs'
    'diagnostics|4|Проверить DNS домена|Записи A/AAAA и IP VPS|dns'
    'recovery|1|Сохранить снимок|Создать резервную копию конфигурации|backup'
    'recovery|2|Восстановить снимок|Выбрать сохранённую конфигурацию|restore'
    'recovery|3|Подтвердить сетевые настройки|Открыть этот пункт из нового SSH-сеанса|confirm'
    'recovery|4|Откатить сетевые изменения|Восстановить конфигурацию до подтверждения|rollback'
    'updates|1|Обновить скрипт|Установить последний релиз с GitHub|update tool'
    'updates|2|Обновить ноду|Применить образ из текущего релиза|update node'
    'updates|3|Откатить версию скрипта|Вернуться к предыдущему релизу|rollback tool'
    'updates|4|Обновить системные пакеты|Nginx, Caddy, Certbot, UFW, Fail2Ban и Docker|update packages'
    'updates|5|Обновить TrafficGuard и список сканеров|Стабильная версия и база из официальных репозиториев|update traffic-guard'
)

show_menu() {
    local page=main parent title heading choice row section index label detail action notice='' id snapshots
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
            IFS='|' read -r section index label detail action <<< "$row"
            [[ $section == "$page" ]] || continue
            labels[$index]=$label
            actions[$index]=$action
            if [[ $page == main ]]; then
                case "$index" in
                    1) printf '  %sУСТАНОВКА%s\n' "$UI_BOLD" "$UI_RESET" ;;
                    3) printf '\n  %sУПРАВЛЕНИЕ%s\n' "$UI_BOLD" "$UI_RESET" ;;
                esac
            fi
            ui_menu_key "$index" "$label"
            if [[ -n $detail && $UI_COMPACT != yes ]]; then
                printf '      %s%s%s\n' "$UI_MUTED" "$detail" "$UI_RESET"
            fi
        done
        printf '\n'
        if [[ $page == main ]]; then
            printf '  %s[0] Выйти%s\n' "$UI_MUTED" "$UI_RESET"
        else
            printf '  %s[0] Назад   [q] Выйти%s\n' "$UI_MUTED" "$UI_RESET"
        fi
        if [[ -n $notice ]]; then
            printf '\n  %s%s%s\n' "${UI_WARN:-$UI_BOLD}" "$notice" "$UI_RESET"
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
                info '  Сохраните первый снимок через пункт «Сохранить снимок».'
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
                info 'Откройте меню снова, чтобы использовать выбранную версию.'
                return 0
            fi
        else
            warn 'Команда завершилась с ошибкой.'
        fi
        ui_pause 'вернуться в меню' || return 0
    done
}
