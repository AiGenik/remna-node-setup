#!/usr/bin/env bash

ui_init() {
    UI_INTERACTIVE=no
    UI_CLEAR=no
    UI_ACCENT=
    UI_RESET=
    UI_VERSION=$(version_get version) || return
    if [[ -t 0 && -t 1 && -t 2 ]]; then
        UI_INTERACTIVE=yes
        if [[ -n ${TERM:-} && $TERM != dumb ]]; then
            UI_CLEAR=yes
            if [[ -z ${NO_COLOR+x} ]]; then
                UI_ACCENT=$'\033[1;36m'
                UI_RESET=$'\033[0m'
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
    printf '  %sRemna Node Setup%s  v%s\n' "$UI_ACCENT" "$UI_RESET" "$UI_VERSION"
    printf '  %s\n' "$1"
    printf '  %s\n\n' '────────────────────────────────────────'
}

ui_section() {
    printf '  %s%s%s\n' "$UI_ACCENT" "$1" "$UI_RESET"
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
    ui_section 'На стороне хостинга и DNS'
    info '  Найдите публичный IPv4 нового VPS в кабинете хостинга.'
    info '  Создайте A-запись для ноды, например node.example.com.'
    info '  В значении A-записи укажите IPv4 этого VPS.'
    info '  Для self-steal домен в Cloudflare должен быть в режиме DNS only.'
    printf '\n'
    ui_section 'В панели Remnawave'
    info '  Ноды → Управление (Nodes → Management) → +.'
    info '  В поле «Домен или IP» введите поддомен ноды и проверьте Node Port.'
    info '  Вверху карточки есть отдельное поле Secret Key (SECRET_KEY).'
    info '  Оба значения есть под кнопкой «Скопировать docker-compose.yml».'
    printf '\n'
    ui_section 'На сервере панели'
    info '  Возьмите исходящий IPv4 панели. Его можно посмотреть по команде'
    info '  curl -4fsS https://api.ipify.org && echo'
    printf '\n'
    info '  Оставьте открытым текущее SSH-подключение к новому VPS.'
}

MENU_ACTIONS=(
    'main|1|Установить ноду и компоненты|Пошаговая настройка нового VPS|install'
    'main|2|Компоненты и защита|Self-steal, UFW, Fail2Ban, BBR и TrafficGuard|@components'
    'main|3|Диагностика|Статус ноды, проверка сервисов и логи|@diagnostics'
    'main|4|Снимки и восстановление|Резервные копии и откат сетевых правил|@recovery'
    'main|5|Обновления|Версии скрипта и ноды|@updates'
    'main|6|Подготовка к установке|Где взять домен, адрес панели, порт и ключ|guide'
    'components|1|Добавить self-steal|Локальный HTTPS-сайт на Caddy|selfsteal'
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
            printf '  %s%2s%s  %s\n' "$UI_ACCENT" "$index" "$UI_RESET" "$label"
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
