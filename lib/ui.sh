#!/usr/bin/env bash

ui_init() {
    UI_INTERACTIVE=no
    UI_CLEAR=no
    UI_ACCENT=
    UI_BOLD=
    UI_MUTED=
    UI_WARN=
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
                UI_MUTED=$'\033[2m'
                UI_WARN=$'\033[1;93m'
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
    printf '  %s◆─●  Remna Node Setup%s  %sv%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$UI_RESET" "$UI_MUTED" "$UI_VERSION" "$UI_RESET"
    if [[ -n $parent ]] && (( ${#parent} + ${#title} + 3 <= UI_RULE_WIDTH )); then
        printf '  %s%s / %s%s%s\n' "$UI_MUTED" "$parent" "$UI_RESET$UI_BOLD" "$title" "$UI_RESET"
    else
        printf '  %s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET"
    fi
    if (( UI_RULE_WIDTH >= 10 )); then
        printf -v line '%*s' "$UI_RULE_WIDTH" ''
        printf '  %s%s%s\n' "$UI_MUTED" "${line// /─}" "$UI_RESET"
    fi
    printf '\n'
}

ui_section() {
    printf '  %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET"
}

ui_step() {
    local i=1 total=${3:-7}
    ui_screen "Шаг $1 из $total" 'Установка ноды'
    printf '  '
    while (( i <= total )); do
        if (( i <= $1 )); then
            printf '%s━%s' "${UI_ACCENT:-$UI_BOLD}" "$UI_RESET"
        else
            printf '%s─%s' "$UI_MUTED" "$UI_RESET"
        fi
        i=$(( i + 1 ))
    done
    printf '  %s%s%s\n\n' "$UI_BOLD" "$2" "$UI_RESET"
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

ui_menu_status() (
    local page=$1 configured='Нода ещё не настроена' address
    if [[ $page == main ]]; then
        if load_config 2>/dev/null; then
            configured='Настройки ноды сохранены'
            if valid_domain "$NODE_DOMAIN" && valid_port "$NODE_PORT"; then
                address=$NODE_DOMAIN:$NODE_PORT
                if (( ${#address} + 11 <= UI_RULE_WIDTH )); then configured="Нода · $address"; fi
            fi
        elif [[ -s ${CONFIG_DIR:-/etc/remna-node-setup}/host.json ]]; then
            configured='Компоненты настроены · ноды пока нет'
        fi
        printf '  %s●%s %s\n' "$UI_ACCENT" "$UI_RESET" "$configured"
    fi
    if [[ -s ${PENDING_FILE:-} ]]; then
        printf '  %s● Сеть ждёт подтверждения SSH%s\n' "${UI_WARN:-$UI_BOLD}" "$UI_RESET"
        if [[ $page == main ]]; then printf '    С нового SSH-сеанса → [4] → [3]\n'; fi
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
    info '  Укажите домен ноды. Скопируйте Node Port и Secret Key.'
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
    'main|1|Установить ноду и компоненты|Пошаговая настройка нового VPS|install'
    'main|2|Компоненты и защита|Self-steal, UFW, Fail2Ban, BBR и TrafficGuard|@components'
    'main|3|Диагностика|Статус ноды, проверка сервисов и логи|@diagnostics'
    'main|4|Снимки и восстановление|Резервные копии и откат сетевых правил|@recovery'
    'main|5|Обновления|Версии скрипта и ноды|@updates'
    'main|6|Подготовка к установке|Где взять домен, адрес панели, порт и ключ|guide'
    'components|1|Настроить self-steal|Caddy или Nginx|selfsteal'
    'components|2|Настроить UFW и Fail2Ban|Правила входящих соединений и защита SSH|security'
    'components|3|Включить BBR и fq|Настройки TCP, если их поддерживает ядро|bbr'
    'components|4|TrafficGuard|Включить или обновить список сканеров|update traffic-guard'
    'components|5|Установить только ноду|Подключение к панели и правила доступа|install node-only'
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
)

show_menu() {
    local page=main parent title choice row section index label detail action notice='' id snapshots
    local -a command=()
    while true; do
        case "$page" in
            main) title='Главное меню' ;;
            components) title='Компоненты и защита' ;;
            diagnostics) title='Диагностика' ;;
            recovery) title='Снимки и восстановление' ;;
            updates) title='Обновления' ;;
        esac
        parent=
        if [[ $page != main ]]; then parent='Меню'; fi
        ui_screen "$title" "$parent"
        ui_menu_status "$page"

        local -A labels=() actions=()
        for row in "${MENU_ACTIONS[@]}"; do
            IFS='|' read -r section index label detail action <<< "$row"
            [[ $section == "$page" ]] || continue
            labels[$index]=$label
            actions[$index]=$action
            ui_menu_key "$index" "$label"
            if [[ $UI_COMPACT != yes ]]; then
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
