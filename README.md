# Remna Node Setup

Мастер установки и обслуживания нод Remnawave. Настройте новую ноду, проверьте связь с панелью и управляйте компонентами из одного терминала.

[Последний релиз](https://github.com/AiGenik/remna-node-setup/releases/latest) · [Документация](docs/Обзор.md) · [Проверки GitHub Actions](https://github.com/AiGenik/remna-node-setup/actions/workflows/release.yml) · [MIT](LICENSE)

**Требования.** Отдельный VPS с Ubuntu 24.04 LTS и systemd на amd64 или arm64, доступ по SSH с правами администратора и действующая панель Remnawave.

## Быстрый старт

Для новой ноды откройте в Remnawave **Ноды → Управление → +**. Укажите адрес VPS и скопируйте `Node Port` и `Secret Key`.

### 1. Установка мастера на VPS

В Терминале на компьютере подключитесь к VPS. Подставьте свой IP.

```bash
ssh root@203.0.113.10
```

В сеансе VPS установите мастер. Установщик скачает стабильный выпуск и сверит SHA-256.

```bash
(
  set -e
  remna_installer=$(mktemp)
  trap 'unlink "$remna_installer"' EXIT
  curl -q -fsSLo "$remna_installer" --proto '=https' \
    https://raw.githubusercontent.com/AiGenik/remna-node-setup/HEAD/install.sh
  sudo bash "$remna_installer" AiGenik/remna-node-setup
)
```

Если мастер уже установлен, вместо блока установки выполните `sudo remna-node-setup update tool`. После успешного завершения введите `exit`, чтобы вернуться в Терминал своего компьютера.

### 2. Установка remna-ssh на компьютере

Откройте локальный Терминал на Mac или Linux. Этот блок скачает помощник, сверит контрольную сумму и установит его в `~/.local/bin`.

```bash
(
  set -e
  remna_stage=$(mktemp -d)
  trap 'cd /; rm -f -- "$remna_stage/remna-ssh" "$remna_stage/remna-ssh.sha256"; rmdir "$remna_stage"' EXIT
  cd "$remna_stage"
  remna_release=https://github.com/AiGenik/remna-node-setup/releases/latest/download
  curl -q -fsSLO --proto '=https' "$remna_release/remna-ssh"
  curl -q -fsSLO --proto '=https' "$remna_release/remna-ssh.sha256"
  if command -v sha256sum >/dev/null; then
    sha256sum -c remna-ssh.sha256
  else
    shasum -a 256 -c remna-ssh.sha256
  fi
  mkdir -p "$HOME/.local/bin"
  install -m 0755 remna-ssh "$HOME/.local/bin/remna-ssh"
)
```

### 3. Запуск меню с компьютера

Для автоматической проверки укажите SSH-алиас панели и адрес ноды. `Panel-TW` здесь — пример алиаса из `~/.ssh/config`. Панель должна открываться по SSH-ключу. Также нужны Python 3.8+ на компьютере и Python 3 на панели.

```bash
"$HOME/.local/bin/remna-ssh" --panel Panel-TW root@203.0.113.10
```

Этот путь работает из любой папки. Команда `./remna-ssh` ищет файл в текущей папке.

Для новой ноды выберите **[1] Только нода** или **[2] Нода и компоненты**. Для проверки готовой ноды выберите **[4] Диагностика → [5] Проверить связь до установки**. На вопросе о проверке с панели нажмите Enter. [Пошаговая установка](docs/Установка.md)

Чтобы открыть обычное меню через помощник, запустите `"$HOME/.local/bin/remna-ssh" root@203.0.113.10`. Для прямого SSH-сеанса меню открывается на VPS командой `sudo remna-node-setup`.

![Главное меню Remna Node Setup](docs/media/menu.png)

## Подтверждение SSH

Если меню открыто через `remna-ssh`, после изменения сетевых правил нажмите Enter. Помощник подтвердит доступ через новое SSH-соединение в том же терминале. Если доступ не подтверждён, VPS запустит автооткат. [Варианты подключения и ручное подтверждение](docs/Эксплуатация.md#подтверждение-ssh)

## Возможности

| Задача | Где найти |
| --- | --- |
| Установить ноду и подготовить входящие порты | **Нода и компоненты** · проверка двусторонней передачи с панели до установки |
| Настроить self-steal или защиту на готовой ноде | **Порты и защита** · Caddy или Nginx, UFW, Fail2Ban, TrafficGuard, BBR и `fq` |
| Настроить Gemini через Psiphon | **Порты и защита → Gemini** · локальный SOCKS5 и [шаблон маршрутизации](docs/Psiphon.md) |
| Проверить соединение, DNS или журналы | **Диагностика** · `preflight`, `doctor`, `dns`, `logs` |
| Обновить компоненты или восстановить настройки | **Обновления** и **Снимки и восстановление** |

## Обновление

```bash
sudo remna-node-setup update tool
```

Команду обновления мастера выполняйте на VPS. Чтобы обновить помощник на компьютере, повторите шаг установки `remna-ssh`. В меню **Обновления → Обновить всё** можно обновить скрипт, ноду и установленные компоненты. Там же включаются ночные автообновления. [Что обновляется и как выполнить откат](docs/Эксплуатация.md#обновление)

## Документация и помощь

- [Установка](docs/Установка.md) · данные из панели, выбор компонентов и входящих портов.
- [Эксплуатация](docs/Эксплуатация.md) · диагностика, обновления и восстановление.
- [Разработка](docs/Разработка.md) · локальные проверки и сборка архива на Ubuntu.
- [История выпусков](https://github.com/AiGenik/remna-node-setup/releases) · изменения и файлы релизов.
- [GitHub Issues](https://github.com/AiGenik/remna-node-setup/issues) · сообщите версию скрипта, версию Ubuntu и команду с ошибкой. Перед публикацией удалите ключи, пароли и токены из вывода.
- [Безопасность](SECURITY.md) · конфиденциальное сообщение об уязвимости.

Для работы в Obsidian откройте папку `docs` как хранилище. Начните с заметки [Обзор](docs/Обзор.md).
