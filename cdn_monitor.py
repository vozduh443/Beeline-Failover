#!/usr/bin/env python3
"""
Beeline CDN Monitor & Auto-Failover

Мониторит технический CDN-домен.
При блокировке/недоступности создаёт ресурс
на следующем аккаунте из БД.

Опционально:
- получает текущий Host из Remnawave;
- автоматически перенастраивает address / sni / host;
- сохраняет остальные параметры Host;
- очищает кеш нового CDN-ресурса через 25 минут.
"""

import sqlite3
import requests
import time
import json
import sys
import os
from datetime import datetime


# ══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ══════════════════════════════════════════════════════════════════════════════

DB_PATH = "/opt/cdn_monitor/accounts.db"
LOG_PATH = "/opt/cdn_monitor/monitor.log"

CHECK_INTERVAL = 60
FAIL_THRESHOLD = 3
CACHE_PURGE_DELAY = 25 * 60

CDN_API = "https://api.cdn.beeline.ru"

REQUEST_TIMEOUT = 15
DOMAIN_CHECK_TIMEOUT = 10


# ══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ══════════════════════════════════════════════════════════════════════════════

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"

    print(line, flush=True)

    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    except Exception:
        pass


# ══════════════════════════════════════════════════════════════════════════════
# DATABASE
# ══════════════════════════════════════════════════════════════════════════════

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute("""
        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT NOT NULL,
            password TEXT NOT NULL,
            account_name TEXT,
            active INTEGER DEFAULT 1,
            used INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)

    c.execute("""
        CREATE TABLE IF NOT EXISTS state (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    """)

    conn.commit()
    conn.close()


def add_account(email, password):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute(
        "INSERT INTO accounts (email, password) VALUES (?, ?)",
        (email, password)
    )

    conn.commit()
    conn.close()

    print(f"✓ Аккаунт {email} добавлен")


def list_accounts():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute("""
        SELECT id, email, account_name, active, used
        FROM accounts
        ORDER BY id
    """)

    rows = c.fetchall()

    conn.close()

    return rows


def get_next_account():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute("""
        SELECT id, email, password
        FROM accounts
        WHERE active=1 AND used=0
        ORDER BY id
        LIMIT 1
    """)

    row = c.fetchone()

    conn.close()

    return row


def mark_account_used(account_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute(
        "UPDATE accounts SET used=1 WHERE id=?",
        (account_id,)
    )

    conn.commit()
    conn.close()


def set_state(key, value):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute(
        "INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)",
        (key, str(value))
    )

    conn.commit()
    conn.close()


def get_state(key, default=None):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    c.execute(
        "SELECT value FROM state WHERE key=?",
        (key,)
    )

    row = c.fetchone()

    conn.close()

    return row[0] if row else default


# ══════════════════════════════════════════════════════════════════════════════
# BEELINE CDN API
# ══════════════════════════════════════════════════════════════════════════════

def get_token(email, password):
    try:
        r = requests.post(
            f"{CDN_API}/app/oauth/v1/token/",
            data={
                "username": email,
                "password": password
            },
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        data = r.json()

        if data.get("status") == 200:
            return data.get("token")

        log(
            f"Не удалось получить токен для {email}: "
            f"HTTP {r.status_code}, response={data}"
        )

    except Exception as e:
        log(f"Ошибка получения токена для {email}: {e}")

    return None


def get_accounts_list(token):
    try:
        r = requests.get(
            f"{CDN_API}/app/inventory/v1/accounts/",
            headers={
                "CDN-AUTH-TOKEN": token
            },
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        data = r.json()

        if isinstance(data, list):
            return data

        if isinstance(data, dict):
            if isinstance(data.get("accounts"), list):
                return data["accounts"]

            if isinstance(data.get("items"), list):
                return data["items"]

        return []

    except Exception as e:
        log(f"Ошибка получения списка CDN-аккаунтов: {e}")
        return []


def create_resource(
    token,
    account_name,
    source_ip,
    hostname,
    sni_hostname
):
    payload = {
        "name": f"failover-{int(time.time())}",
        "active": True,

        "origin": {
            "https": True,

            "servers": {
                source_ip: {
                    "port": 443,
                    "backup": False
                }
            },

            "hostname": hostname,
            "sni_hostname": sni_hostname,

            "read_timeout": "300s",
            "send_timeout": "300s",
            "connect_timeout": "5s"
        },

        "cache": {
            "valid": {
                "2xx": "0s",
                "3xx": "0s",
                "4xx": "0s",
                "5xx": "0s",
                "force": False,
                "browser": "0s"
            },

            "use_stale": False,
            "consider_args": True,
            "consider_cookies": False
        },

        "http2https": True,
        "modern_tls_only": True,

        "allowed_http_methods": [
            "POST",
            "PUT",
            "DELETE",
            "PATCH"
        ]
    }

    try:
        r = requests.post(
            f"{CDN_API}/cdn/api/v1/{account_name}/resource/http",

            headers={
                "CDN-AUTH-TOKEN": token,
                "Content-Type": "application/json"
            },

            json=payload,

            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        try:
            return r.json()
        except Exception:
            log(
                f"CDN API вернул не-JSON: "
                f"HTTP {r.status_code}: {r.text[:500]}"
            )
            return None

    except Exception as e:
        log(f"Ошибка создания ресурса: {e}")
        return None


def purge_cache(token, account_name, resource_id):
    try:
        r = requests.post(
            f"{CDN_API}/cdn/api/v1/"
            f"{account_name}/resource/http/"
            f"{resource_id}/purge",

            headers={
                "CDN-AUTH-TOKEN": token,
                "Content-Type": "application/json"
            },

            json={
                "paths": [
                    "/*"
                ]
            },

            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        return r.status_code == 200

    except Exception as e:
        log(f"Ошибка очистки кеша: {e}")
        return False


# ══════════════════════════════════════════════════════════════════════════════
# REMNAWAVE API
# ══════════════════════════════════════════════════════════════════════════════

def remnawave_enabled():
    return (
        get_state("remnawave_url")
        and get_state("remnawave_token")
        and get_state("remnawave_host_uuid")
    )


def remnawave_headers():
    return {
        "Authorization": f"Bearer {get_state('remnawave_token')}",
        "Content-Type": "application/json"
    }


def remnawave_url(path):
    base = get_state("remnawave_url", "").rstrip("/")

    return f"{base}{path}"


def get_remnawave_host():
    if not remnawave_enabled():
        return None

    host_uuid = get_state("remnawave_host_uuid")

    try:
        r = requests.get(
            remnawave_url(f"/api/hosts/{host_uuid}"),
            headers=remnawave_headers(),
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        if r.status_code != 200:
            log(
                f"Remnawave: ошибка получения Host "
                f"HTTP {r.status_code}: {r.text[:500]}"
            )
            return None

        data = r.json()

        if isinstance(data, dict) and "response" in data:
            return data["response"]

        return data

    except Exception as e:
        log(f"Remnawave: ошибка получения Host: {e}")

    return None


def show_remnawave_host(host):
    if not host:
        return

    print()
    print("── Текущий Host Remnawave ──")
    print(f"  UUID:    {host.get('uuid', 'неизвестно')}")
    print(f"  Address: {host.get('address', 'не задан')}")
    print(f"  Port:    {host.get('port', 'не задан')}")
    print(f"  Path:    {host.get('path', 'не задан')}")
    print(f"  SNI:     {host.get('sni', 'не задан')}")
    print(f"  Host:    {host.get('host', 'не задан')}")

    extra = host.get("xhttpExtraParams")

    if isinstance(extra, dict):
        headers = extra.get("headers", {})

        if isinstance(headers, dict):
            print(
                f"  Origin:  "
                f"{headers.get('Origin', 'не задан')}"
            )

            print(
                f"  Referer: "
                f"{headers.get('Referer', 'не задан')}"
            )

    print()


def update_remnawave_host(new_domain):
    if not remnawave_enabled():
        return False

    host_uuid = get_state("remnawave_host_uuid")

    current_host = get_remnawave_host()

    if not current_host:
        log(
            "Remnawave: не удалось получить текущий Host, "
            "обновление отменено"
        )
        return False

    payload = {
        "uuid": host_uuid
    }

    # Сохраняем все существующие поля.
    # Меняем только параметры, связанные с CDN-доменом.

    for key, value in current_host.items():
        if key in [
            "uuid",
            "createdAt",
            "updatedAt"
        ]:
            continue

        payload[key] = value

    payload["address"] = new_domain
    payload["sni"] = new_domain
    payload["host"] = new_domain

    # Если Host использует xhttpExtraParams,
    # сохраняем его полностью и меняем только path/headers
    # при наличии соответствующих настроек.

    extra = payload.get("xhttpExtraParams")

    if isinstance(extra, dict):
        extra = dict(extra)

        headers = extra.get("headers")

        if isinstance(headers, dict):
            headers = dict(headers)
            extra["headers"] = headers

        payload["xhttpExtraParams"] = extra

    try:
        r = requests.patch(
            remnawave_url("/api/hosts"),
            headers=remnawave_headers(),
            json=payload,
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        if r.status_code in [200, 201, 204]:
            log(
                f"✓ Remnawave Host обновлён: "
                f"{new_domain}"
            )
            return True

        log(
            f"✗ Remnawave: ошибка обновления Host "
            f"HTTP {r.status_code}: {r.text[:1000]}"
        )

    except Exception as e:
        log(
            f"✗ Remnawave: ошибка обновления Host: {e}"
        )

    return False


# ══════════════════════════════════════════════════════════════════════════════
# DOMAIN CHECK
# ══════════════════════════════════════════════════════════════════════════════

def check_cdn_domain(cdn_domain):
    if not cdn_domain:
        return False

    url = f"https://{cdn_domain}"

    try:
        r = requests.get(
            url,
            timeout=DOMAIN_CHECK_TIMEOUT,
            verify=False,
            allow_redirects=True
        )

        return r.status_code not in [
            403,
            502,
            503
        ]

    except Exception:
        return False


# ══════════════════════════════════════════════════════════════════════════════
# FAILOVER
# ══════════════════════════════════════════════════════════════════════════════

def do_failover(config):
    log("═══ FAILOVER НАЧАТ ═══")

    account = get_next_account()

    if not account:
        log("ОШИБКА: Нет доступных аккаунтов в БД!")
        return None

    acc_id, email, password = account

    log(f"Используем аккаунт: {email}")

    token = get_token(
        email,
        password
    )

    if not token:
        log(
            f"ОШИБКА: Не удалось получить токен для {email}"
        )
        return None

    accounts = get_accounts_list(token)

    if not accounts:
        log(
            "ОШИБКА: Не удалось получить список "
            "аккаунтов CDN"
        )
        return None

    account_name = accounts[0].get("name")

    if not account_name:
        log(
            f"ОШИБКА: Не найдено имя CDN-аккаунта: "
            f"{accounts[0]}"
        )
        return None

    log(f"Аккаунт CDN: {account_name}")

    result = create_resource(
        token,
        account_name,
        config["source_ip"],
        config["hostname"],
        config["sni_hostname"]
    )

    if not result or "id" not in result:
        log(
            f"ОШИБКА: Не удалось создать ресурс: "
            f"{result}"
        )
        return None

    resource_id = result["id"]

    cdn_domain = result.get(
        "cdn_domain",
        ""
    )

    log(
        f"✓ Ресурс создан: {resource_id}"
    )

    log(
        f"✓ Новый тех домен: {cdn_domain}"
    )

    if not cdn_domain:
        log(
            "ОШИБКА: CDN API не вернул cdn_domain"
        )
        return None

    # ──────────────────────────────────────────────────────────────────────────
    # Отмечаем аккаунт использованным
    # ──────────────────────────────────────────────────────────────────────────

    mark_account_used(acc_id)

    # ──────────────────────────────────────────────────────────────────────────
    # Сохраняем состояние
    # ──────────────────────────────────────────────────────────────────────────

    set_state(
        "current_cdn_domain",
        cdn_domain
    )

    set_state(
        "current_resource_id",
        resource_id
    )

    set_state(
        "current_account_name",
        account_name
    )

    set_state(
        "current_token",
        token
    )

    set_state(
        "purge_at",
        time.time() + CACHE_PURGE_DELAY
    )

    # ──────────────────────────────────────────────────────────────────────────
    # Remnawave
    # ──────────────────────────────────────────────────────────────────────────

    if remnawave_enabled():
        log(
            "Обновляем Host в Remnawave..."
        )

        if update_remnawave_host(cdn_domain):
            log(
                "✓ Remnawave Host автоматически "
                "перенастроен"
            )
        else:
            log(
                "✗ Не удалось автоматически "
                "перенастроить Host Remnawave"
            )
    else:
        log(
            "Remnawave интеграция отключена"
        )

    log(
        "⏳ Очистка кеша через 25 минут"
    )

    log(
        "═══ FAILOVER ЗАВЕРШЁН ═══"
    )

    return cdn_domain


# ══════════════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════════════

def setup():
    print()
    print("╔══════════════════════════════════════════╗")
    print("║     Beeline CDN Monitor — Настройка      ║")
    print("╚══════════════════════════════════════════╝")
    print()

    source_ip = input(
        "IP адрес источника "
        "(например 46.8.254.25): "
    ).strip()

    hostname = input(
        "Hostname / Host заголовок "
        "(например cab.example.com): "
    ).strip()

    sni_hostname = input(
        "SNI hostname "
        "(обычно тот же): "
    ).strip()

    if not sni_hostname:
        sni_hostname = hostname

    cdn_domain = input(
        "Текущий тех домен CDN "
        "(например mgh6qg7nf5.a.trbcdn.net): "
    ).strip()

    if not source_ip:
        print("✗ IP источника не указан")
        return

    if not hostname:
        print("✗ Hostname не указан")
        return

    if not cdn_domain:
        print("✗ CDN домен не указан")
        return

    set_state(
        "source_ip",
        source_ip
    )

    set_state(
        "hostname",
        hostname
    )

    set_state(
        "sni_hostname",
        sni_hostname
    )

    set_state(
        "current_cdn_domain",
        cdn_domain
    )

    print()
    print("✓ Конфиг сохранён")
    print()
    print(f"  Источник:   {source_ip}")
    print(f"  Hostname:   {hostname}")
    print(f"  SNI:        {sni_hostname}")
    print(f"  Тех домен:  {cdn_domain}")
    print()


# ══════════════════════════════════════════════════════════════════════════════
# REMNAWAVE SETUP
# ══════════════════════════════════════════════════════════════════════════════

def setup_remnawave():
    print()
    print("── Настройка Remnawave ──")
    print()

    enabled = input(
        "Включить автоматическую перенастройку Host? "
        "[y/N]: "
    ).strip().lower()

    if enabled not in [
        "y",
        "yes",
        "д",
        "да"
    ]:
        set_state(
            "remnawave_enabled",
            "0"
        )

        print(
            "✓ Интеграция Remnawave отключена"
        )

        return

    panel_url = input(
        "Remnawave Panel URL "
        "(например https://panel.example.com): "
    ).strip().rstrip("/")

    token = input(
        "Remnawave API Token: "
    ).strip()

    host_uuid = input(
        "UUID Host: "
    ).strip()

    if not panel_url:
        print("✗ URL не указан")
        return

    if not token:
        print("✗ API Token не указан")
        return

    if not host_uuid:
        print("✗ UUID Host не указан")
        return

    set_state(
        "remnawave_enabled",
        "1"
    )

    set_state(
        "remnawave_url",
        panel_url
    )

    set_state(
        "remnawave_token",
        token
    )

    set_state(
        "remnawave_host_uuid",
        host_uuid
    )

    print()
    print("Проверяем Host...")

    host = get_remnawave_host()

    if not host:
        print(
            "✗ Не удалось получить Host из Remnawave"
        )
        return

    print(
        "✓ Host успешно получен"
    )

    show_remnawave_host(host)


# ══════════════════════════════════════════════════════════════════════════════
# ACCOUNT SETUP
# ══════════════════════════════════════════════════════════════════════════════

def add_account_interactive():
    print()
    print("── Добавление аккаунта Beeline CDN ──")
    print()

    email = input(
        "Email: "
    ).strip()

    password = input(
        "Пароль: "
    ).strip()

    if not email or not password:
        print(
            "✗ Email и пароль обязательны"
        )
        return

    print(
        "Проверяем аккаунт..."
    )

    token = get_token(
        email,
        password
    )

    if not token:
        print(
            "✗ Не удалось войти в аккаунт"
        )
        return

    add_account(
        email,
        password
    )

    print(
        "✓ Аккаунт добавлен и проверен"
    )


# ══════════════════════════════════════════════════════════════════════════════
# STATUS
# ══════════════════════════════════════════════════════════════════════════════

def show_status():
    print()
    print("── Состояние ──")

    print(
        f"  Тех домен:    "
        f"{get_state('current_cdn_domain', 'не задан')}"
    )

    print(
        f"  Источник:     "
        f"{get_state('source_ip', 'не задан')}"
    )

    print(
        f"  Hostname:     "
        f"{get_state('hostname', 'не задан')}"
    )

    print(
        f"  SNI:          "
        f"{get_state('sni_hostname', 'не задан')}"
    )

    print()

    if remnawave_enabled():
        print(
            "  Remnawave:    ✓ включён"
        )

        print(
            f"  Panel:        "
            f"{get_state('remnawave_url')}"
        )

        print(
            f"  Host UUID:    "
            f"{get_state('remnawave_host_uuid')}"
        )
    else:
        print(
            "  Remnawave:    отключён"
        )

    print()
    print("── Аккаунты в БД ──")

    accounts = list_accounts()

    if not accounts:
        print(
            "  Нет аккаунтов"
        )
        return

    for acc in accounts:
        acc_id, email, account_name, active, used = acc

        status = (
            "✓ свободен"
            if not used
            else "✗ использован"
        )

        active_status = (
            ""
            if active
            else " [отключен]"
        )

        name = (
            account_name
            if account_name
            else "CDN account не сохранён"
        )

        print(
            f"  [{acc_id}] "
            f"{email} — {status}{active_status}"
        )

        print(
            f"       CDN: {name}"
        )


# ══════════════════════════════════════════════════════════════════════════════
# MONITOR
# ══════════════════════════════════════════════════════════════════════════════

def run_monitor():
    cdn_domain = get_state(
        "current_cdn_domain"
    )

    source_ip = get_state(
        "source_ip"
    )

    hostname = get_state(
        "hostname"
    )

    sni_hostname = get_state(
        "sni_hostname"
    )

    if not all([
        cdn_domain,
        source_ip,
        hostname
    ]):
        print(
            "Сначала выполните настройку:"
        )

        print(
            "python3 cdn_monitor.py setup"
        )

        sys.exit(1)

    if not sni_hostname:
        sni_hostname = hostname

    config = {
        "source_ip": source_ip,
        "hostname": hostname,
        "sni_hostname": sni_hostname
    }

    log(
        f"Монитор запущен. "
        f"Слежу за: {cdn_domain}"
    )

    fail_count = 0

    while True:
        try:
            # ──────────────────────────────────────────────────────────────────
            # PURGE CACHE
            # ──────────────────────────────────────────────────────────────────

            purge_at = get_state(
                "purge_at"
            )

            if purge_at:
                try:
                    purge_at_float = float(
                        purge_at
                    )
                except (ValueError, TypeError):
                    purge_at_float = 0

                if (
                    purge_at_float > 0
                    and purge_at_float < time.time()
                ):
                    token = get_state(
                        "current_token"
                    )

                    account_name = get_state(
                        "current_account_name"
                    )

                    resource_id = get_state(
                        "current_resource_id"
                    )

                    if (
                        token
                        and account_name
                        and resource_id
                    ):
                        log(
                            "Очищаем кеш CDN..."
                        )

                        if purge_cache(
                            token,
                            account_name,
                            resource_id
                        ):
                            log(
                                "✓ Кеш очищен"
                            )
                        else:
                            log(
                                "✗ Не удалось очистить кеш"
                            )

                    set_state(
                        "purge_at",
                        ""
                    )

            # ──────────────────────────────────────────────────────────────────
            # CURRENT DOMAIN
            # ──────────────────────────────────────────────────────────────────

            cdn_domain = get_state(
                "current_cdn_domain"
            )

            if not cdn_domain:
                log(
                    "ОШИБКА: текущий CDN-домен не задан"
                )

                time.sleep(
                    CHECK_INTERVAL
                )

                continue

            # ──────────────────────────────────────────────────────────────────
            # CHECK
            # ──────────────────────────────────────────────────────────────────

            if check_cdn_domain(
                cdn_domain
            ):
                if fail_count > 0:
                    log(
                        f"Домен снова доступен "
                        f"после {fail_count} ошибок"
                    )

                fail_count = 0

            else:
                fail_count += 1

                log(
                    f"Домен недоступен "
                    f"({fail_count}/{FAIL_THRESHOLD}): "
                    f"{cdn_domain}"
                )

                if fail_count >= FAIL_THRESHOLD:
                    new_domain = do_failover(
                        config
                    )

                    if new_domain:
                        log(
                            f"Переключились на: "
                            f"{new_domain}"
                        )

                        fail_count = 0

                    else:
                        log(
                            "Failover не удался, "
                            "ждём следующей попытки"
                        )

            time.sleep(
                CHECK_INTERVAL
            )

        except KeyboardInterrupt:
            log(
                "Монитор остановлен пользователем"
            )
            break

        except Exception as e:
            log(
                f"Критическая ошибка цикла мониторинга: {e}"
            )

            time.sleep(
                CHECK_INTERVAL
            )


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    import urllib3

    urllib3.disable_warnings(
        urllib3.exceptions.InsecureRequestWarning
    )

    init_db()

    if len(sys.argv) < 2:
        print()
        print("╔══════════════════════════════════════════╗")
        print("║       Beeline CDN Monitor v1.0           ║")
        print("╚══════════════════════════════════════════╝")
        print()
        print("Использование:")
        print()
        print(
            "  python3 cdn_monitor.py setup"
        )
        print(
            "      — первичная настройка"
        )
        print()
        print(
            "  python3 cdn_monitor.py add"
        )
        print(
            "      — добавить аккаунт Beeline"
        )
        print()
        print(
            "  python3 cdn_monitor.py remnawave"
        )
        print(
            "      — настроить Remnawave"
        )
        print()
        print(
            "  python3 cdn_monitor.py status"
        )
        print(
            "      — показать состояние"
        )
        print()
        print(
            "  python3 cdn_monitor.py monitor"
        )
        print(
            "      — запустить мониторинг"
        )
        print()

        return

    cmd = sys.argv[1].lower()

    if cmd == "setup":
        setup()

    elif cmd == "add":
        add_account_interactive()

    elif cmd == "remnawave":
        setup_remnawave()

    elif cmd == "status":
        show_status()

    elif cmd == "monitor":
        run_monitor()

    else:
        print(
            f"Неизвестная команда: {cmd}"
        )


if __name__ == "__main__":
    main()
