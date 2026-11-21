# Remna Node Setup

Мастер установки ноды Remnawave на Ubuntu 24.04. Нужна работающая панель Remnawave.

## Новый VPS

Выполните на сервере. Команда установит последний стабильный релиз и откроет меню.

```bash
f=$(mktemp) && curl -q -fsSLo "$f" --proto =https https://raw.githubusercontent.com/AiGenik/remna-node-setup/HEAD/install.sh && sudo bash "$f" && rm -f "$f"
```

В панели откройте «Ноды → Управление → +». Приготовьте адрес VPS, Node Port и Secret Key.

- **Только нода** — Docker и Remnawave Node.
- **Нода и компоненты** — нода и защита, с выбором self-steal, BBR и TrafficGuard.

После изменения firewall подтвердите доступ командой `sudo remna-node-setup confirm` из нового SSH-сеанса.

## Уже установлен

```bash
sudo remna-node-setup update tool && sudo remna-node-setup
```

В меню «Обновления» выберите **Обновить всё** или включите **Автообновления**.

Для локального выхода Psiphon откройте «Порты и защита → Настроить Psiphon».

- [Установка и подключение к панели](docs/Установка.md)
- [Обновление, резервные копии и восстановление](docs/Эксплуатация.md)
- [Psiphon и шаблон Gemini](docs/Psiphon.md)
- [Обзор проекта](docs/Обзор.md)

Для работы в Obsidian откройте папку `docs` как хранилище и начните с заметки «Обзор».
