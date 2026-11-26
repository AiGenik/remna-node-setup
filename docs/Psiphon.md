# Psiphon

Psiphon даёт ноде отдельный выход через SOCKS5 на `127.0.0.1:1080`. Для него нужен Docker Engine 28 или новее. На новом VPS мастер поставит Docker. Адрес и порт доступны только на VPS. [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) · [Публикация портов Docker](https://docs.docker.com/engine/network/port-publishing/)

1. В мастере **[1] Всё под ключ** Psiphon для Gemini включён по умолчанию — достаточно выбрать регион (`auto`, конкретную страну `CA` или список через запятую `CA,NL,DE`) и порт (по умолчанию `1080`). Для готовой ноды откройте **[2] Установка и настройка по частям → [8] Psiphon для Gemini**.
2. Включён встроенный **watchdog** (`vps-psiphon-watchdog.timer`, без фоновой закачки `--bulk-test-mb 0`, `MIN_THROUGHPUT_KBPS=0`): он регулярно проверяет страну выхода (`DENY_REGIONS='RU BY IR SY CU KP CN VE'`) и доступность Gemini, автоматически перезапуская туннель и переключая регион из резервного пула `REGION_POOL`, если сервер начал определяться как `RU` или получил отказ `1060`.
3. Проверьте статус командой `sudo remna-node-setup psiphon status` (или через **[3] → [3] Живой тест: Gemini, YouTube и Certbot**).

Управляемый Psiphon входит в «Обновить всё» и автообновления. При установке и обновлении мастер автоматически подтягивает последний стабильный релиз `Chara-Freedom/vps-psiphon` и проверяет наложение безопасных патчей (`--bind-loopback`, отключение HTTP-прокси); если структура апстрима несовместима, используется проверенная встроенная версия. Ручная установка `vps-psiphon` сохраняет своё управление. Каждая нода поднимает собственный изолированный `vps-psiphon` на `127.0.0.1:1080` и не пересылает трафик через другие ноды. При смене региона через `vps-psiphon region КОД` (например `CA` или `NL`) `status`, `doctor` и `update` учитывают активный `EGRESS_REGION` из `/etc/default/vps-psiphon`.

## Шаблон Gemini

В **[2] Установка и настройка по частям → [9] Шаблон Gemini для Remnawave** (по умолчанию — **`all`**, для всех текущих и будущих нод без `localIP`) формируется готовый JSON.

```bash
sudo remna-node-setup psiphon profile
```

Если профиль нужно привязать только к одной ноде, передайте её IP (`sudo remna-node-setup psiphon profile IP_НОДЫ`).

В панели Remnawave откройте нужный Config Profile, например XHTTP или GRPC. Перенесите элементы `outbounds` и `routing.rules` из шаблона в существующие массивы. Правила должны стоять раньше общего правила маршрутизации.

Если профиль уже настроен, сохраните его как `profile.json` на VPS и выполните команду — мастер обновит домены Gemini/Antigravity, добавит правило `youtube-direct` и переведёт правила в глобальный режим (для всех нод без `localIP`):

```bash
umask 077
sudo remna-node-setup psiphon profile-merge < profile.json > profile-new.json
```

Шаблон первым правилом (`youtube-direct`) отправляет YouTube (`geosite:youtube`, `youtube.com`, `googlevideo.com`, `ytimg.com`, `youtu.be`) строго напрямую (`DIRECT`), а затем отправляет TCP к хостам Gemini и Antigravity (`gemini.google.com`, `aistudio.google.com`, `generativelanguage.googleapis.com`, `antigravity.google` и др.) через `psiphon-out` и блокирует UDP/443 к тем же хостам. Без `localIP` правило работает сразу на всех текущих и новых нодах (при условии, что на каждой ноде включён `vps-psiphon` на `127.0.0.1:1080`). [Маршрутизация Xray](https://xtls.github.io/en/config/routing.html)
