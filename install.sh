#!/usr/bin/env python3
"""
Beeline CDN Monitor & Auto-Failover
Мониторит тех домен, при бане создаёт ресурс на следующем аккаунте из БД
и опционально перенастраивает Host в Remnawave.
"""

import sqlite3
import requests
import time
import json
import sys
import os
from datetime import datetime

DB_PATH = "/opt/cdn_monitor/accounts.db"
LOG_PATH = "/opt/cdn_monitor/monitor.log"
CHECK_INTERVAL = 60  # секунд между проверками
FAIL_THRESHOLD = 3   # кол-во фейлов подряд перед переключением
CACHE_PURGE_DELAY = 25 * 60  # 25 минут в секундах

CDN_API = "https://api.cdn.beeline.ru"


# ─── Логирование ────────────────────────────────────────────────────────────

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)

    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")


# ─── БД ─────────────────────────────────────────────────────────────────────

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

    c.execute(
        "SELECT id, email, account_name, active, used FROM accounts"
    )

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


# ─── Beeline CDN API ─────────────────────────────────────────────────────────

def get_token(email, password):
    try:
        r = requests.post(
            f"{CDN_API}/app/oauth/v1/token/",
            data={
                "username": email,
                "password": password
            },
            verify=False,
            timeout=15
        )

        data = r.json()

        if data.get("status") == 200:
            return data["token"]

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
            timeout=15
        )

        return r.json()

    except Exception:
        return []


def create_resource(token, account_name, source_ip, hostname, sni_hostname):
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
            timeout=15
        )

        return r.json()

    except Exception as e:
        log(f"Ошибка создания ресурса: {e}")
        return None


def purge_cache(token, account_name, resource_id):
    try:
        r = requests.post(
            f"{CDN_API}/cdn/api/v1/{account_name}/resource/http/{resource_id}/purge",
            headers={
                "CDN-AUTH-TOKEN": token,
                "Content-Type": "application/json"
            },
            json={
                "paths": ["/*"]
            },
            verify=False,
            timeout=15
        )

        return r.status_code == 200

    except Exception:
        return False


# ─── Remnawave API ──────────────────────────────────────────────────────────

def remnawave_enabled():
    return get_state("remnawave_enabled", "0") == "1"


def get_remnawave_config():
    return {
        "panel_url": get_state("remnawave_panel_url"),
        "token": get_state("remnawave_token"),
        "host_uuid": get_state("remnawave_host_uuid")
    }


def get_remnawave_host():
    """
    Получает актуальную конфигурацию Host из Remnawave.
    """

    config = get_remnawave_config()

    panel_url = config["panel_url"]
    token = config["token"]
    host_uuid = config["host_uuid"]

    if not panel_url or not token or not host_uuid:
        log("Remnawave: конфигурация не заполнена")
        return None

    panel_url = panel_url.rstrip("/")

    try:
        r = requests.get(
            f"{panel_url}/api/hosts/{host_uuid}",
            headers={
                "Authorization": f"Bearer {token}"
            },
            verify=False,
            timeout=15
        )

        if r.status_code != 200:
            log(
                f"Remnawave: ошибка получения Host "
                f"(HTTP {r.status_code}): {r.text}"
            )
            return None

        data = r.json()

        if "response" in data:
            return data["response"]

        return data

    except Exception as e:
        log(f"Remnawave: ошибка получения Host: {e}")
        return None


def update_remnawave_host(new_cdn_domain):
    """
    Перенастраивает существующий Host Remnawave на новый CDN-домен.

    Основные поля:
      address -> новый CDN domain
      sni     -> новый CDN domain
      host    -> новый CDN domain

    Остальные параметры сохраняются.
    """

    config = get_remnawave_config()

    panel_url = config["panel_url"]
    token = config["token"]
    host_uuid = config["host_uuid"]

    if not panel_url or not token or not host_uuid:
        log("Remnawave: недостаточно данных для обновления Host")
        return False

    # Сначала обязательно получаем актуальный Host.
    host = get_remnawave_host()

    if not host:
        log("Remnawave: не удалось получить текущий Host")
        return False

    old_address = host.get("address", "")
    old_sni = host.get("sni", "")
    old_host = host.get("host", "")
    old_path = host.get("path", "")

    log("Remnawave: текущий Host получен")
    log(f"  address: {old_address}")
    log(f"  sni:     {old_sni}")
    log(f"  host:    {old_host}")
    log(f"  path:    {old_path}")

    # ─────────────────────────────────────────────────────────────
    # Формируем минимальный PATCH.
    #
    # Не отправляем весь объект Host обратно в API.
    # Меняем только нужные параметры.
    # ─────────────────────────────────────────────────────────────

    payload = {
        "uuid": host_uuid,
        "address": new_cdn_domain,
        "sni": new_cdn_domain,
        "host": new_cdn_domain
    }

    # Path сохраняем явно, если он существует.
    if "path" in host:
        payload["path"] = host.get("path")

    # Если в Host есть xhttpExtraParams — сохраняем его структуру.
    #
    # ВАЖНО:
    # Origin и Referer находятся внутри:
    #
    # xhttpExtraParams.headers
    #
    # Мы не пересоздаём весь объект с нуля, а сохраняем существующие
    # параметры и только при необходимости оставляем Origin/Referer.
    if "xhttpExtraParams" in host:
        xhttp_extra = host.get("xhttpExtraParams")

        if isinstance(xhttp_extra, dict):
            payload["xhttpExtraParams"] = xhttp_extra

    panel_url = panel_url.rstrip("/")

    try:
        log(
            f"Remnawave: обновляем Host "
            f"{host_uuid} -> {new_cdn_domain}"
        )

        r = requests.patch(
            f"{panel_url}/api/hosts",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            },
            json=payload,
            verify=False,
            timeout=20
        )

        # Remnawave может вернуть 200/204 в зависимости от версии.
        if r.status_code not in [200, 204]:
            log(
                f"Remnawave: ошибка обновления Host "
                f"(HTTP {r.status_code}): {r.text}"
            )
            return False

        log("✓ Remnawave Host успешно обновлён")
        log(f"  Новый address: {new_cdn_domain}")
        log(f"  Новый SNI:     {new_cdn_domain}")
        log(f"  Новый Host:    {new_cdn_domain}")

        return True

    except Exception as e:
        log(f"Remnawave: ошибка PATCH Host: {e}")
        return False


# ─── Проверка доступности ────────────────────────────────────────────────────

def check_cdn_domain(cdn_domain):
    url = f"https://{cdn_domain}"

    try:
        r = requests.get(
            url,
            timeout=10,
            verify=False,
            allow_redirects=True
        )

        return r.status_code not in [403, 502, 503]

    except Exception:
        return False


# ─── Failover ────────────────────────────────────────────────────────────────

def do_failover(config):
    log("═══ FAILOVER НАЧАТ ═══")

    account = get_next_account()

    if not account:
        log("ОШИБКА: Нет доступных аккаунтов в БД!")
        return None

    acc_id, email, password = account

    log(f"Используем аккаунт: {email}")

    token = get_token(email, password)

    if not token:
        log(
            f"ОШИБКА: Не удалось получить токен для {email}"
        )
        return None

    accounts = get_accounts_list(token)

    if not accounts:
        log(
            "ОШИБКА: Не удалось получить список аккаунтов"
        )
        return None

    account_name = accounts[0]["name"]

    log(f"Аккаунт CDN: {account_name}")

    # ─────────────────────────────────────────────────────────────
    # Создание нового ресурса — ОСНОВНАЯ ЛОГИКА НЕ ИЗМЕНЕНА
    # ─────────────────────────────────────────────────────────────

    result = create_resource(
        token,
        account_name,
        config["source_ip"],
        config["hostname"],
        config["sni_hostname"]
    )

    if not result or "id" not in result:
        log(
            f"ОШИБКА: Не удалось создать ресурс: {result}"
        )
        return None

    resource_id = result["id"]
    cdn_domain = result.get("cdn_domain", "")

    log(f"✓ Ресурс создан: {resource_id}")
    log(f"✓ Новый тех домен: {cdn_domain}")

    if not cdn_domain:
        log(
            "ОШИБКА: API не вернул cdn_domain"
        )
        return None

    # ─────────────────────────────────────────────────────────────
    # Помечаем аккаунт использованным
    # ─────────────────────────────────────────────────────────────

    mark_account_used(acc_id)

    # ─────────────────────────────────────────────────────────────
    # Сохраняем новое состояние
    # ─────────────────────────────────────────────────────────────

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
        str(time.time() + CACHE_PURGE_DELAY)
    )

    # ─────────────────────────────────────────────────────────────
    # НОВОЕ:
    # Перенастройка Host Remnawave.
    #
    # Если отключено — старое поведение полностью сохраняется.
    # ─────────────────────────────────────────────────────────────

    if remnawave_enabled():
        log("Remnawave: автоматическая перенастройка включена")

        if update_remnawave_host(cdn_domain):
            log(
                "✓ Remnawave Host переключён на новый тех домен"
            )
        else:
            log(
                "✗ Remnawave Host не удалось обновить"
            )

    log("⏳ Очистка кеша через 25 минут")
    log("═══ FAILOVER ЗАВЕРШЁН ═══")

    return cdn_domain


# ─── Интерактивная настройка ─────────────────────────────────────────────────

def setup():
    print("\n╔══════════════════════════════════════════╗")
    print("║     Beeline CDN Monitor — Настройка     ║")
    print("╚══════════════════════════════════════════╝\n")

    source_ip = input(
        "IP адрес источника "
        "(например 46.8.254.25): "
    ).strip()

    hostname = input(
        "Hostname / Host заголовок "
        "(например cab.powpowders.store): "
    ).strip()

    sni_hostname = input(
        "SNI hostname (обычно тот же): "
    ).strip() or hostname

    cdn_domain = input(
        "Текущий тех домен CDN для мониторинга "
        "(например mgh6qg7nf5.a.trbcdn.net): "
    ).strip()

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

    # ─────────────────────────────────────────────────────────────
    # Remnawave
    # ─────────────────────────────────────────────────────────────

    print("\n── Remnawave ──")

    rw_enabled = input(
        "Автоматически перенастраивать Host Remnawave? [y/N]: "
    ).strip().lower()

    if rw_enabled in ["y", "yes", "д", "да"]:
        set_state(
            "remnawave_enabled",
            "1"
        )

        panel_url = input(
            "Адрес Remnawave Panel "
            "(например https://panel.example.com): "
        ).strip()

        token = input(
            "Remnawave API Token: "
        ).strip()

        host_uuid = input(
            "UUID Host: "
        ).strip()

        set_state(
            "remnawave_panel_url",
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

        # ─────────────────────────────────────────────────────────
        # Проверяем Host прямо во время setup.
        # ─────────────────────────────────────────────────────────

        print("\nПроверяем Remnawave Host...")

        host = get_remnawave_host()

        if host:
            print("✓ Host успешно получен")

            print(
                f"  UUID:     {host.get('uuid', '')}"
            )

            print(
                f"  Address:  {host.get('address', '')}"
            )

            print(
                f"  SNI:      {host.get('sni', '')}"
            )

            print(
                f"  Host:     {host.get('host', '')}"
            )

            print(
                f"  Path:     {host.get('path', '')}"
            )

            xhttp_extra = host.get(
                "xhttpExtraParams",
                {}
            )

            if isinstance(xhttp_extra, dict):
                headers = xhttp_extra.get(
                    "headers",
                    {}
                )

                if isinstance(headers, dict):
                    print(
                        f"  Origin:   "
                        f"{headers.get('Origin', '')}"
                    )

                    print(
                        f"  Referer:  "
                        f"{headers.get('Referer', '')}"
                    )

        else:
            print(
                "✗ Не удалось получить Host."
            )

            print(
                "Проверь Panel URL, API Token и UUID."
            )

    else:
        set_state(
            "remnawave_enabled",
            "0"
        )

        print(
            "Remnawave: автоматическая перенастройка отключена"
        )

    print("\n✓ Конфиг сохранён")

    print(
        f"  Источник:   "
        f"{source_ip}"
    )

    print(
        f"  Hostname:   "
        f"{hostname}"
    )

    print(
        f"  SNI:        "
        f"{sni_hostname}"
    )

    print(
        f"  Тех домен:  "
        f"{cdn_domain}"
    )

    print(
        f"  Remnawave:  "
        f"{'включён' if remnawave_enabled() else 'выключен'}"
    )

    print()


def add_account_interactive():
    print("\n── Добавление аккаунта Beeline CDN ──")

    email = input(
        "Email: "
    ).strip()

    password = input(
        "Пароль: "
    ).strip()

    # Проверяем что аккаунт рабочий

    print("Проверяем аккаунт...")

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


def show_status():
    print("\n── Состояние ──")

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
        f"  Remnawave:    "
        f"{'включён' if remnawave_enabled() else 'выключен'}"
    )

    if remnawave_enabled():
        print(
            f"  Panel:        "
            f"{get_state('remnawave_panel_url', 'не задан')}"
        )

        print(
            f"  Host UUID:    "
            f"{get_state('remnawave_host_uuid', 'не задан')}"
        )

    print("\n── Аккаунты в БД ──")

    accounts = list_accounts()

    if not accounts:
        print("  Нет аккаунтов")

    else:
        for acc in accounts:
            status = (
                "✓ свободен"
                if not acc[4]
                else "✗ использован"
            )

            active = (
                ""
                if acc[3]
                else " [отключен]"
            )

            print(
                f"  [{acc[0]}] "
                f"{acc[1]} — "
                f"{status}"
                f"{active}"
            )


# ─── Основной монитор ────────────────────────────────────────────────────────

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
            "Сначала выполните настройку: "
            "python3 cdn_monitor.py setup"
        )

        sys.exit(1)

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

        # ─────────────────────────────────────────────────────────
        # Проверяем нужна ли очистка кеша
        # ─────────────────────────────────────────────────────────

        purge_at = get_state(
            "purge_at"
        )

        if purge_at and float(purge_at) < time.time():

            token = get_state(
                "current_token"
            )

            account_name = get_state(
                "current_account_name"
            )

            resource_id = get_state(
                "current_resource_id"
            )

            if token and account_name and resource_id:

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

        # ─────────────────────────────────────────────────────────
        # Берём актуальный домен
        # ─────────────────────────────────────────────────────────

        cdn_domain = get_state(
            "current_cdn_domain"
        )

        if check_cdn_domain(cdn_domain):

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


# ─── Точка входа ─────────────────────────────────────────────────────────────

def main():

    import urllib3

    urllib3.disable_warnings()

    init_db()

    if len(sys.argv) < 2:

        print("""
╔══════════════════════════════════════════╗
║       Beeline CDN Monitor v1.0           ║
╚══════════════════════════════════════════╝

Использование:
  python3 cdn_monitor.py setup       — первичная настройка
  python3 cdn_monitor.py add         — добавить аккаунт Beeline
  python3 cdn_monitor.py status      — показать состояние
  python3 cdn_monitor.py monitor     — запустить мониторинг
        """)

        return

    cmd = sys.argv[1]

    if cmd == "setup":
        setup()

    elif cmd == "add":
        add_account_interactive()

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
