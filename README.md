# Remna Node Setup

Русскоязычный мастер для новой ноды Remnawave на VPS с Ubuntu 24.04. Устанавливает Docker Compose, ноду, Caddy или Nginx для self-steal, UFW, Fail2Ban и по выбору TrafficGuard и BBR. Панель Remnawave должна уже работать.

## Быстрый старт

Приготовьте домен ноды, IP-адреса, с которых панель подключается к ноде, и параметры `NODE_PORT` и `SECRET_KEY` из панели.

На VPS выполните команду для релиза 0.2.0.

```bash
f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/AiGenik/remna-node-setup/v0.2.0/install.sh -o "$f" && sudo bash "$f" AiGenik/remna-node-setup v0.2.0 && rm -f "$f" && sudo remna-node-setup
```

Для установки из локальной папки с исходниками используйте следующие команды.

```bash
sudo ./install.sh --local
sudo remna-node-setup
```

В меню выберите «Установить ноду и компоненты». После сетевых изменений откройте новое SSH-подключение и выполните `sudo remna-node-setup confirm`. До подтверждения действует таймер отката на 10 минут.

В разделе «Компоненты и защита» ноду, self-steal, BBR, UFW с Fail2Ban и TrafficGuard можно настроить по отдельности. Раздел «Диагностика» проверяет DNS домена и показывает, на какие IP должны указывать записи.

- [Установка и подключение к панели](docs/Установка.md)
- [Обновление, резервные копии и восстановление](docs/Эксплуатация.md)
- [Обзор проекта](docs/Обзор.md)

Для работы в Obsidian откройте папку `docs` как хранилище и начните с заметки «Обзор».
