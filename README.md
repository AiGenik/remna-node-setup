# Remna Node Setup

Русскоязычный мастер для новой ноды Remnawave на VPS с Ubuntu 24.04. Устанавливает Docker Compose, ноду, Caddy или Nginx для self-steal, UFW, Fail2Ban и по выбору TrafficGuard и BBR. Панель Remnawave должна уже работать.

## Быстрый старт

Приготовьте адрес новой ноды, `NODE_PORT` и `SECRET_KEY` из панели. Для настройки защиты также нужны исходящий IP панели и порты профиля Xray.

На VPS выполните команду для релиза 0.3.0.

```bash
f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/AiGenik/remna-node-setup/v0.3.0/install.sh -o "$f" && sudo bash "$f" AiGenik/remna-node-setup v0.3.0 && rm -f "$f" && sudo remna-node-setup
```

Для установки из локальной папки с исходниками используйте следующие команды.

```bash
sudo ./install.sh --local
sudo remna-node-setup
```

В меню выберите «Только нода» или «Нода и компоненты». После сетевых изменений откройте новое SSH-подключение и выполните `sudo remna-node-setup confirm`. До подтверждения действует таймер отката на 10 минут.

В разделе «Порты и защита» можно отдельно настроить входящие TCP/UDP-порты, self-steal, UFW с Fail2Ban, BBR и TrafficGuard. Диагностика проверяет DNS, слушающие порты Xray и разрешения UFW.

- [Установка и подключение к панели](docs/Установка.md)
- [Обновление, резервные копии и восстановление](docs/Эксплуатация.md)
- [Обзор проекта](docs/Обзор.md)

Для работы в Obsidian откройте папку `docs` как хранилище и начните с заметки «Обзор».
