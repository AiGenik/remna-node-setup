#!/usr/bin/env bash

ui_init() {
    UI_INTERACTIVE=no
    UI_CLEAR=no
    UI_ACCENT=
    UI_BOLD=
    UI_RESET=
    UI_VERSION=$(version_get version) || return
    if [[ -t 0 && -t 1 && -t 2 ]]; then
        UI_INTERACTIVE=yes
        if [[ -n ${TERM:-} && $TERM != dumb ]]; then
            UI_CLEAR=yes
            UI_BOLD=$'\033[1m'
            UI_RESET=$'\033[0m'
            if [[ -z ${NO_COLOR+x} ]]; then
                UI_ACCENT=$'\033[1;36m'
            fi
        fi
    fi
}

ui_screen() {
    if [[ $UI_CLEAR == yes ]]; then
        # Redraw the viewport and leave the SSH terminal's scrollback intact.
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
    printf '  %sRemna Node Setup%s  v%s\n\n' "${UI_ACCENT:-$UI_BOLD}" "$UI_RESET" "$UI_VERSION"
    printf '  %s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"
    printf '  %s\n\n' '────────────────────────────────────────'
}

ui_section() {
    printf '  %s%s%s\n' "${UI_ACCENT:-$UI_BOLD}" "$1" "$UI_RESET"
}

ui_step() {
    ui_screen "Установка ноды  /  Шаг $1 из 7"
    ui_section "$2"
}

ui_pause() {
    if [[ $UI_INTERACTIVE != yes ]]; then return 0; fi
    printf '\n  Enter — %s ' "$1" >&2
    IFS= read -r
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
    'components|4|Включить или обновить TrafficGuard|Список известных сканеров|update traffic-guard'
    'diagnostics|1|Статус|Нода и установленные компоненты|status'
    'diagnostics|2|Проверить сервисы|Порты, компоненты и место на диске|doctor'
    'diagnostics|3|Логи ноды|Последние сообщения контейнера|logs'
    'recovery|1|Сохранить снимок|Создать резервную копию конфигурации|backup'
    'recovery|2|Восстановить снимок|Выбрать сохранённую конфигурацию|restore'
    'recovery|3|Подтвердить сетевые настройки|Открыть этот пункт из нового SSH-сеанса|confirm'
    'recovery|4|Отменить ожидающие изменения сети|Восстановить конфигурацию до подтверждения|rollback'
    'updates|1|Обновить скрипт|Установить последний релиз с GitHub|update tool'
    'updates|2|Обновить ноду|Применить образ из текущего релиза|update node'
    'updates|3|Откатить версию скрипта|Вернуться к предыдущему релизу|rollback tool'
)

show_menu() {
    local page=main title choice row section index label detail action notice='' id
    local -a command=()
    while true; do
        case "$page" in
            main) title='Главное меню' ;;
            components) title='Компоненты и защита' ;;
            diagnostics) title='Диагностика' ;;
            recovery) title='Снимки и восстановление' ;;
            updates) title='Обновления' ;;
        esac
        ui_screen "$title"
        if [[ $page == main && -s $PENDING_FILE ]]; then
            info '  Сеть ждёт подтверждения из нового SSH-подключения.'
            printf '\n'
        fi

        local -A labels=() actions=()
        for row in "${MENU_ACTIONS[@]}"; do
            IFS='|' read -r section index label detail action <<< "$row"
            [[ $section == "$page" ]] || continue
            labels[$index]=$label
            actions[$index]=$action
            printf '  %s%2s%s  %s%s%s\n' "$UI_ACCENT" "$index" "$UI_RESET" "$UI_BOLD" "$label" "$UI_RESET"
            printf '      %s\n' "$detail"
        done
        if [[ $page == main ]]; then
            info '   0  Выйти'
        else
            info '   0  Назад'
        fi
        printf '\n'
        if [[ -n $notice ]]; then warn "$notice"; notice=; fi
        choice=$(prompt '  Номер пункта →') || return 0
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
            *) ui_screen "${labels[$choice]}" ;;
        esac

        read -r -a command <<< "$action"
        if [[ $action == restore ]]; then
            find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '  %f\n' | sort -r
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
