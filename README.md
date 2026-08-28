# 🚀 Beeline CDN Failover

Автоматический failover для **Beeline CDN** с поддержкой нескольких аккаунтов и опциональной автоматической перенастройкой Host в **Remnawave**.

Если текущий технический CDN-домен перестаёт отвечать, скрипт автоматически:

1. обнаруживает недоступность домена;
2. берёт следующий свободный аккаунт из базы;
3. авторизуется в Beeline CDN;
4. создаёт новый CDN-ресурс;
5. получает новый технический домен;
6. сохраняет новое состояние;
7. при необходимости автоматически меняет `address`, `sni` и `host` существующего Host в Remnawave;
8. планирует очистку кеша нового ресурса через 25 минут.

Основная логика failover сохраняется независимо от того, включена ли интеграция с Remnawave.

## ✨ Возможности

* 🔄 Автоматическое переключение на следующий аккаунт Beeline CDN
* 👤 Неограниченное количество аккаунтов в SQLite-базе
* 🔐 Проверка аккаунта перед добавлением
* 🌐 Автоматическое создание нового CDN-ресурса
* 📡 Получение нового технического CDN-домена
* 🔧 Опциональная интеграция с Remnawave API
* 🔄 Автоматическое изменение Host в Remnawave
* 🧹 Автоматический purge кеша через 25 минут
* 💾 Сохранение состояния между перезапусками
* 📝 Подробное логирование
* ⚙️ Работа в режиме постоянного мониторинга

## 📦 Что используется

Скрипт использует:

* Python 3
* `requests`
* SQLite
* Beeline CDN API
* Remnawave API — опционально

База и лог создаются автоматически:

```text
/opt/cdn_monitor/accounts.db
/opt/cdn_monitor/monitor.log
```

Путь к базе и логу определён непосредственно в скрипте.

## 🚀 Установка

Репозиторий:

[vozduh443/Beeline-Failover](https://github.com/vozduh443/Beeline-Failover/tree/main?utm_source=chatgpt.com)

Если `install.sh` используется как установочный файл репозитория, запуск:

```bash
curl -fsSL https://raw.githubusercontent.com/vozduh443/Beeline-Failover/main/install.sh | bash
```

После установки используется:

```bash
python3 cdn_monitor.py
```

## ⚙️ Первичная настройка

Запусти:

```bash
python3 cdn_monitor.py setup
```

Скрипт запросит:

```text
IP адрес источника
Hostname / Host заголовок
SNI hostname
Текущий технический домен CDN
```

Эти параметры сохраняются в SQLite и используются при создании следующего CDN-ресурса.

### Remnawave

Интеграция с Remnawave является опциональной.

При включении необходимо указать:

```text
Remnawave Panel URL
Remnawave API Token
UUID Host
```

После этого скрипт сразу проверяет доступность указанного Host через API Remnawave и выводит его текущие параметры:

```text
Address
SNI
Host
Path
Origin
Referer
```

## 👤 Добавление аккаунтов Beeline CDN

Для добавления аккаунта:

```bash
python3 cdn_monitor.py add
```

Будут запрошены:

```text
Email
Пароль
```

Перед сохранением скрипт проверяет возможность авторизации в Beeline CDN.

Можно добавить несколько аккаунтов:

```text
Account 1
Account 2
Account 3
Account 4
...
```

При failover используется первый активный аккаунт, который ещё не был использован. После успешного создания ресурса аккаунт помечается как использованный.

## 📊 Просмотр состояния

```bash
python3 cdn_monitor.py status
```

Показывает:

* текущий технический домен;
* IP источника;
* Hostname;
* состояние интеграции Remnawave;
* Panel URL;
* UUID Host;
* список аккаунтов;
* какие аккаунты свободны;
* какие уже использованы.

## 🔄 Запуск мониторинга

```bash
python3 cdn_monitor.py monitor
```

Монитор проверяет текущий технический домен каждые **60 секунд**.

После **3 последовательных ошибок** запускается failover.

Проверка считает домен недоступным при:

```text
403
502
503
```

а также при сетевой ошибке/таймауте.

### Схема работы

```text
                 ┌──────────────────────┐
                 │ Текущий CDN-домен    │
                 └──────────┬───────────┘
                            │
                            ▼
                       Проверка
                            │
              ┌─────────────┴─────────────┐
              │                           │
           Доступен                   Недоступен
              │                           │
              ▼                           ▼
          Продолжаем                 3 ошибки подряд
                                         │
                                         ▼
                                Следующий аккаунт
                                         │
                                         ▼
                                  Авторизация CDN
                                         │
                                         ▼
                                  Создание ресурса
                                         │
                                         ▼
                                  Новый CDN-домен
                                         │
                                         ▼
                               ┌─────────┴─────────┐
                               │                   │
                          Remnawave ON        Remnawave OFF
                               │                   │
                               ▼                   │
                         Обновление Host           │
                               │                   │
                               └─────────┬─────────┘
                                         ▼
                                  Новый домен активен
```

## 🔧 Интеграция с Remnawave

При включённой интеграции перед изменением Host скрипт сначала получает его актуальную конфигурацию через:

```text
GET /api/hosts/{uuid}
```

После этого выполняется минимальное обновление:

```text
address → новый CDN-домен
sni     → новый CDN-домен
host    → новый CDN-домен
```

Существующие параметры Host сохраняются, включая `path` и структуру `xhttpExtraParams`.
Запрос обновления выполняется через:

```text
PATCH /api/hosts
```

## 🧹 Очистка кеша

После успешного failover скрипт устанавливает таймер очистки кеша:

```text
25 минут
```

После наступления времени выполняется purge:

```text
/*
```

для нового ресурса.

## 📝 Логи

Лог сохраняется в:

```text
/opt/cdn_monitor/monitor.log
```

Пример:

```text
[2026-08-28 20:15:01] Монитор запущен. Слежу за: mgh6qg7nf5.a.trbcdn.net
[2026-08-28 20:16:01] Домен недоступен (1/3): mgh6qg7nf5.a.trbcdn.net
[2026-08-28 20:17:01] Домен недоступен (2/3): mgh6qg7nf5.a.trbcdn.net
[2026-08-28 20:18:01] Домен недоступен (3/3): mgh6qg7nf5.a.trbcdn.net
[2026-08-28 20:18:01] ═══ FAILOVER НАЧАТ ═══
[2026-08-28 20:18:02] Используем аккаунт: account@example.com
[2026-08-28 20:18:03] ✓ Ресурс создан
[2026-08-28 20:18:03] ✓ Новый тех домен: xxxxx.a.trbcdn.net
[2026-08-28 20:18:03] ✓ Remnawave Host успешно обновлён
```

## 🖥️ Автозапуск

Мониторинг рассчитан на постоянную работу.

Для production рекомендуется запускать:

```bash
python3 cdn_monitor.py monitor
```

через `systemd`, чтобы сервис автоматически стартовал после перезагрузки сервера и перезапускался при падении процесса.

Пример unit-файла:

```ini
[Unit]
Description=Beeline CDN Failover Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/cdn_monitor/cdn_monitor.py monitor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

После создания сервиса:

```bash
systemctl daemon-reload
systemctl enable --now beeline-failover
```

Проверка:

```bash
systemctl status beeline-failover
```

## 🔐 Безопасность

Скрипт хранит учётные данные Beeline CDN и API-токен Remnawave локально в SQLite.

Поэтому:

* не публикуйте `accounts.db`;
* не публикуйте `monitor.log`;
* не добавляйте их в Git;
* ограничьте права доступа к `/opt/cdn_monitor`;
* API-токен Remnawave не публикуйте в issue или README.

Рекомендуется добавить в `.gitignore`:

```gitignore
*.db
*.log
__pycache__/
```

## ⚠️ Важно

Скрипт предназначен для автоматизации failover уже настроенного CDN-ресурса.

При failover новый ресурс создаётся с параметрами:

```text
HTTPS origin
Source IP
Hostname
SNI hostname
POST
PUT
DELETE
PATCH
```

а кеширование для ответов `2xx–5xx` устанавливается в `0s`.

## 📋 Команды

| Команда   | Назначение                   |
| --------- | ---------------------------- |
| `setup`   | Первичная настройка          |
| `add`     | Добавить аккаунт Beeline CDN |
| `status`  | Показать состояние           |
| `monitor` | Запустить мониторинг         |

Примеры:

```bash
python3 cdn_monitor.py setup
```

```bash
python3 cdn_monitor.py add
```

```bash
python3 cdn_monitor.py status
```

```bash
python3 cdn_monitor.py monitor
```

## 📄 Лицензия

Используйте проект на свой страх и риск.

Автор: **vozduh443**

Репозиторий:

[GitHub — vozduh443/Beeline-Failover](https://github.com/vozduh443/Beeline-Failover/tree/main?utm_source=chatgpt.com)
