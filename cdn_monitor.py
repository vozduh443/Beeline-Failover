#!/usr/bin/env python3

import os
import sys
import time
import json
import sqlite3
import getpass
from datetime import datetime

import requests
import urllib3


# ══════════════════════════════════════════════════════════════════════════════
# CONFIG
# ══════════════════════════════════════════════════════════════════════════════

DB_PATH = "/opt/cdn_monitor/accounts.db"
LOG_PATH = "/opt/cdn_monitor/monitor.log"

CDN_API = "https://api.cdn.beeline.ru"

CHECK_INTERVAL = 60
FAIL_THRESHOLD = 3
CACHE_PURGE_DELAY = 25 * 60

REQUEST_TIMEOUT = 15
DOMAIN_CHECK_TIMEOUT = 10


# ══════════════════════════════════════════════════════════════════════════════
# COLORS
# ══════════════════════════════════════════════════════════════════════════════

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
BLUE = "\033[0;34m"
WHITE = "\033[1;37m"
GRAY = "\033[0;90m"
RESET = "\033[0m"


def clear():
    os.system("clear 2>/dev/null || true")


def header(title="Beeline CDN Failover"):
    print()
    print(f"{CYAN}╔══════════════════════════════════════════════════════════╗{RESET}")
    print(f"{CYAN}║{RESET}  {WHITE}{title:<54}{RESET}{CYAN}║{RESET}")
    print(f"{CYAN}╚══════════════════════════════════════════════════════════╝{RESET}")
    print()


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

def db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = db()
    cur = conn.cursor()

    cur.execute("""
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

    cur.execute("""
        CREATE TABLE IF NOT EXISTS state (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    """)

    conn.commit()
    conn.close()


def set_state(key, value):
    conn = db()
    conn.execute(
        "INSERT OR REPLACE INTO state(key,value) VALUES(?,?)",
        (key, str(value))
    )
    conn.commit()
    conn.close()


def get_state(key, default=None):
    conn = db()

    row = conn.execute(
        "SELECT value FROM state WHERE key=?",
        (key,)
    ).fetchone()

    conn.close()

    return row["value"] if row else default


def delete_state(key):
    conn = db()

    conn.execute(
        "DELETE FROM state WHERE key=?",
        (key,)
    )

    conn.commit()
    conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# BEELINE
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
            f"Ошибка авторизации {email}: "
            f"HTTP {r.status_code}: {data}"
        )

    except Exception as e:
        log(f"Ошибка авторизации {email}: {e}")

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
        log(f"Ошибка получения CDN аккаунтов: {e}")
        return []


def add_account(email, password):
    token = get_token(email, password)

    if not token:
        return False

    accounts = get_accounts_list(token)

    account_name = None

    if accounts:
        account_name = accounts[0].get("name")

    conn = db()

    conn.execute(
        """
        INSERT INTO accounts
        (email,password,account_name,active,used)
        VALUES(?,?,?,?,?)
        """,
        (
            email,
            password,
            account_name,
            1,
            0
        )
    )

    conn.commit()
    conn.close()

    return True


def list_accounts():
    conn = db()

    rows = conn.execute(
        """
        SELECT id,email,account_name,active,used,created_at
        FROM accounts
        ORDER BY id
        """
    ).fetchall()

    conn.close()

    return rows


def delete_account(account_id):
    conn = db()

    cur = conn.execute(
        "DELETE FROM accounts WHERE id=?",
        (account_id,)
    )

    conn.commit()
    deleted = cur.rowcount > 0

    conn.close()

    return deleted


def reset_account(account_id):
    conn = db()

    cur = conn.execute(
        """
        UPDATE accounts
        SET used=0, active=1
        WHERE id=?
        """,
        (account_id,)
    )

    conn.commit()
    changed = cur.rowcount > 0

    conn.close()

    return changed


def toggle_account(account_id):
    conn = db()

    row = conn.execute(
        "SELECT active FROM accounts WHERE id=?",
        (account_id,)
    ).fetchone()

    if not row:
        conn.close()
        return False

    new_status = 0 if row["active"] else 1

    conn.execute(
        "UPDATE accounts SET active=? WHERE id=?",
        (new_status, account_id)
    )

    conn.commit()
    conn.close()

    return True


def delete_all_accounts():
    conn = db()
    conn.execute("DELETE FROM accounts")
    conn.commit()
    conn.close()


# ══════════════════════════════════════════════════════════════════════════════
# CDN RESOURCE
# ══════════════════════════════════════════════════════════════════════════════

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
            f"{CDN_API}/cdn/api/v1/"
            f"{account_name}/resource/http",

            headers={
                "CDN-AUTH-TOKEN": token,
                "Content-Type": "application/json"
            },

            json=payload,

            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        return r.json()

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
                "paths": ["/*"]
            },

            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        return r.status_code == 200

    except Exception as e:
        log(f"Ошибка purge: {e}")
        return False


# ══════════════════════════════════════════════════════════════════════════════
# REMNAWAVE
# ══════════════════════════════════════════════════════════════════════════════

def remnawave_enabled():
    return bool(
        get_state("remnawave_url")
        and get_state("remnawave_token")
        and get_state("remnawave_host_uuid")
    )


def remna_headers():
    return {
        "Authorization": (
            f"Bearer {get_state('remnawave_token')}"
        ),
        "Content-Type": "application/json"
    }


def remna_url(path):
    return (
        get_state("remnawave_url", "").rstrip("/")
        + path
    )


def get_remnawave_host():
    if not remnawave_enabled():
        return None

    uuid = get_state("remnawave_host_uuid")

    try:
        r = requests.get(
            remna_url(f"/api/hosts/{uuid}"),
            headers=remna_headers(),
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        if r.status_code != 200:
            log(
                f"Remnawave GET Host: HTTP "
                f"{r.status_code}: {r.text[:500]}"
            )
            return None

        data = r.json()

        return data.get("response", data)

    except Exception as e:
        log(f"Ошибка Remnawave GET Host: {e}")
        return None


def extract_host_values(host):
    extra = host.get("xhttpExtraParams") or {}
    headers = extra.get("headers") or {}

    return {
        "address": host.get("address", ""),
        "sni": host.get("sni", ""),
        "host": host.get("host", ""),
        "path": host.get("path", ""),
        "origin": headers.get("Origin", ""),
        "referer": headers.get("Referer", "")
    }


def show_host(host):
    values = extract_host_values(host)

    print()
    print(f"{CYAN}── Remnawave Host ──{RESET}")

    print(f"  Address : {values['address']}")
    print(f"  SNI     : {values['sni']}")
    print(f"  Host    : {values['host']}")
    print(f"  Path    : {values['path']}")
    print(f"  Origin  : {values['origin']}")
    print(f"  Referer : {values['referer']}")
    print()


def setup_remnawave():
    print()
    print(f"{CYAN}── Настройка Remnawave ──{RESET}")
    print()

    url = input(
        "Panel URL "
        "(например https://panel.example.com): "
    ).strip().rstrip("/")

    if not url:
        print(f"{RED}✗ URL не указан{RESET}")
        return False

    token = getpass.getpass(
        "API Token: "
    ).strip()

    if not token:
        print(f"{RED}✗ Token не указан{RESET}")
        return False

    uuid = input(
        "UUID Host: "
    ).strip()

    if not uuid:
        print(f"{RED}✗ UUID Host не указан{RESET}")
        return False

    set_state("remnawave_url", url)
    set_state("remnawave_token", token)
    set_state("remnawave_host_uuid", uuid)

    print()
    print("Получаем Host из Remnawave...")

    host = get_remnawave_host()

    if not host:
        print(
            f"{RED}✗ Не удалось получить Host.{RESET}"
        )
        return False

    print(f"{GREEN}✓ Host получен{RESET}")

    show_host(host)

    values = extract_host_values(host)

    print(
        "Параметры выше будут сохранены "
        "как текущая конфигурация Host."
    )

    for key in [
        "address",
        "sni",
        "host",
        "path",
        "origin",
        "referer"
    ]:
        set_state(
            f"host_{key}",
            values[key]
        )

    set_state(
        "remnawave_configured",
        "1"
    )

    print(
        f"{GREEN}✓ Remnawave настроен{RESET}"
    )

    return True


def update_remnawave_host(new_domain):
    if not remnawave_enabled():
        return False

    host = get_remnawave_host()

    if not host:
        return False

    payload = dict(host)

    payload["uuid"] = host["uuid"]

    # Меняем только CDN endpoint.
    payload["address"] = new_domain
    payload["sni"] = new_domain
    payload["host"] = new_domain

    try:
        r = requests.patch(
            remna_url("/api/hosts"),
            headers=remna_headers(),
            json=payload,
            verify=False,
            timeout=REQUEST_TIMEOUT
        )

        if r.status_code in [200, 201, 204]:
            log(
                f"✓ Remnawave Host обновлён: "
                f"{new_domain}"
            )

            set_state(
                "host_address",
                new_domain
            )

            set_state(
                "host_sni",
                new_domain
            )

            set_state(
                "host_host",
                new_domain
            )

            return True

        log(
            f"Remnawave PATCH Host: HTTP "
            f"{r.status_code}: {r.text[:1000]}"
        )

    except Exception as e:
        log(
            f"Ошибка обновления Remnawave Host: {e}"
        )

    return False


# ══════════════════════════════════════════════════════════════════════════════
# CHECK
# ══════════════════════════════════════════════════════════════════════════════

def check_cdn_domain(domain):
    if not domain:
        return False

    try:
        r = requests.get(
            f"https://{domain}",
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

def get_next_account():
    conn = db()

    row = conn.execute(
        """
        SELECT id,email,password
        FROM accounts
        WHERE active=1 AND used=0
        ORDER BY id
        LIMIT 1
        """
    ).fetchone()

    conn.close()

    return row


def mark_account_used(account_id):
    conn = db()

    conn.execute(
        "UPDATE accounts SET used=1 WHERE id=?",
        (account_id,)
    )

    conn.commit()
    conn.close()


def do_failover():
    log("═══ FAILOVER НАЧАТ ═══")

    account = get_next_account()

    if not account:
        log(
            "ОШИБКА: Нет свободных аккаунтов."
        )
        return None

    account_id = account["id"]
    email = account["email"]
    password = account["password"]

    source_ip = get_state("source_ip")
    hostname = get_state("hostname")
    sni = get_state("sni_hostname") or hostname

    log(
        f"Используем аккаунт: {email}"
    )

    token = get_token(
        email,
        password
    )

    if not token:
        log(
            "ОШИБКА: Авторизация не удалась."
        )
        return None

    accounts = get_accounts_list(token)

    if not accounts:
        log(
            "ОШИБКА: Не удалось получить "
            "список CDN аккаунтов."
        )
        return None

    account_name = accounts[0].get("name")

    if not account_name:
        log(
            "ОШИБКА: Не найдено имя CDN аккаунта."
        )
        return None

    result = create_resource(
        token,
        account_name,
        source_ip,
        hostname,
        sni
    )

    if not result:
        log(
            "ОШИБКА: CDN API не вернул результат."
        )
        return None

    resource_id = result.get("id")
    cdn_domain = result.get("cdn_domain")

    if not resource_id or not cdn_domain:
        log(
            f"ОШИБКА создания ресурса: {result}"
        )
        return None

    log(
        f"✓ Ресурс создан: {resource_id}"
    )

    log(
        f"✓ Новый тех домен: {cdn_domain}"
    )

    mark_account_used(account_id)

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

    if remnawave_enabled():
        log(
            "Обновляем Host в Remnawave..."
        )

        if update_remnawave_host(
            cdn_domain
        ):
            log(
                "✓ Remnawave Host перенастроен"
            )
        else:
            log(
                "✗ Remnawave Host не удалось "
                "перенастроить"
            )

    log(
        "⏳ Очистка кеша через 25 минут"
    )

    log("═══ FAILOVER ЗАВЕРШЁН ═══")

    return cdn_domain


# ══════════════════════════════════════════════════════════════════════════════
# SETUP
# ══════════════════════════════════════════════════════════════════════════════

def setup_main():
    print()
    print(f"{CYAN}── Основная настройка ──{RESET}")
    print()

    source_ip = input(
        "IP источника: "
    ).strip()

    hostname = input(
        "Origin Hostname / Host: "
    ).strip()

    sni = input(
        f"SNI [{hostname}]: "
    ).strip()

    if not sni:
        sni = hostname

    cdn_domain = input(
        "Текущий CDN тех-домен: "
    ).strip()

    if not source_ip:
        print(
            f"{RED}✗ IP не указан{RESET}"
        )
        return False

    if not hostname:
        print(
            f"{RED}✗ Hostname не указан{RESET}"
        )
        return False

    if not cdn_domain:
        print(
            f"{RED}✗ CDN домен не указан{RESET}"
        )
        return False

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
        sni
    )

    set_state(
        "current_cdn_domain",
        cdn_domain
    )

    print()
    print(
        f"{GREEN}✓ Основная конфигурация сохранена{RESET}"
    )

    print()
    answer = input(
        "Настроить Remnawave сейчас? [Y/n]: "
    ).strip().lower()

    if answer not in [
        "n",
        "no",
        "н",
        "нет"
    ]:
        setup_remnawave()

    return True


def check_config():
    required = [
        "source_ip",
        "hostname",
        "sni_hostname",
        "current_cdn_domain"
    ]

    missing = [
        key
        for key in required
        if not get_state(key)
    ]

    if missing:
        print(
            f"{RED}Не заполнено:{RESET}"
        )

        for item in missing:
            print(
                f"  - {item}"
            )

        return False

    return True


# ══════════════════════════════════════════════════════════════════════════════
# STATUS
# ══════════════════════════════════════════════════════════════════════════════

def status():
    clear()
    header("Статус")

    print(
        f"{WHITE}CDN:{RESET} "
        f"{get_state('current_cdn_domain', 'не задан')}"
    )

    print(
        f"{WHITE}Origin IP:{RESET} "
        f"{get_state('source_ip', 'не задан')}"
    )

    print(
        f"{WHITE}Hostname:{RESET} "
        f"{get_state('hostname', 'не задан')}"
    )

    print(
        f"{WHITE}SNI:{RESET} "
        f"{get_state('sni_hostname', 'не задан')}"
    )

    print()

    if remnawave_enabled():
        print(
            f"{GREEN}Remnawave: включён{RESET}"
        )

        print(
            f"Panel: "
            f"{get_state('remnawave_url')}"
        )

        print(
            f"Host UUID: "
            f"{get_state('remnawave_host_uuid')}"
        )

    else:
        print(
            f"{GRAY}Remnawave: отключён{RESET}"
        )

    print()

    rows = list_accounts()

    print(
        f"{CYAN}── Аккаунты Beeline CDN ──{RESET}"
    )

    if not rows:
        print("Нет аккаунтов.")
    else:
        for row in rows:
            active = (
                f"{GREEN}ON{RESET}"
                if row["active"]
                else f"{RED}OFF{RESET}"
            )

            used = (
                f"{RED}USED{RESET}"
                if row["used"]
                else f"{GREEN}FREE{RESET}"
            )

            print(
                f"[{row['id']}] "
                f"{row['email']} "
                f"[{active}] [{used}]"
            )

    print()


# ══════════════════════════════════════════════════════════════════════════════
# ACCOUNT MENU
# ══════════════════════════════════════════════════════════════════════════════

def accounts_menu():
    while True:
        clear()
        header("Аккаунты Beeline CDN")

        rows = list_accounts()

        if rows:
            for row in rows:
                active = "✓" if row["active"] else "✗"
                used = "USED" if row["used"] else "FREE"

                print(
                    f"  [{row['id']}] "
                    f"{row['email']} "
                    f"| {active} | {used}"
                )
        else:
            print(
                f"{GRAY}Аккаунтов пока нет.{RESET}"
            )

        print()
        print("  1. Добавить аккаунт")
        print("  2. Удалить аккаунт")
        print("  3. Сбросить USED → FREE")
        print("  4. Включить / отключить")
        print("  5. Удалить ВСЕ аккаунты")
        print("  0. Назад")
        print()

        choice = input(
            "Выберите действие: "
        ).strip()

        if choice == "1":
            add_account_menu()

        elif choice == "2":
            remove_account_menu()

        elif choice == "3":
            reset_account_menu()

        elif choice == "4":
            toggle_account_menu()

        elif choice == "5":
            delete_all_accounts_menu()

        elif choice == "0":
            return


def add_account_menu():
    print()

    email = input(
        "Email: "
    ).strip()

    password = getpass.getpass(
        "Пароль: "
    ).strip()

    if not email or not password:
        print(
            f"{RED}✗ Заполните оба поля.{RESET}"
        )
        input("Enter...")
        return

    print(
        "Проверяем аккаунт..."
    )

    if add_account(
        email,
        password
    ):
        print(
            f"{GREEN}✓ Аккаунт добавлен.{RESET}"
        )
    else:
        print(
            f"{RED}✗ Аккаунт не добавлен.{RESET}"
        )

    input("Enter...")


def remove_account_menu():
    rows = list_accounts()

    if not rows:
        input("Нет аккаунтов. Enter...")
        return

    print()

    account_id = input(
        "ID аккаунта для удаления: "
    ).strip()

    if not account_id.isdigit():
        return

    row = next(
        (
            x
            for x in rows
            if x["id"] == int(account_id)
        ),
        None
    )

    if not row:
        print(
            f"{RED}Аккаунт не найден.{RESET}"
        )
        input("Enter...")
        return

    print()
    print(
        f"Удалить {row['email']}?"
    )

    confirm = input(
        "Введите YES для подтверждения: "
    ).strip()

    if confirm != "YES":
        print("Отменено.")
        input("Enter...")
        return

    if delete_account(
        int(account_id)
    ):
        print(
            f"{GREEN}✓ Аккаунт удалён.{RESET}"
        )

    input("Enter...")


def reset_account_menu():
    account_id = input(
        "ID аккаунта для сброса: "
    ).strip()

    if not account_id.isdigit():
        return

    if reset_account(
        int(account_id)
    ):
        print(
            f"{GREEN}✓ Аккаунт снова FREE/ACTIVE.{RESET}"
        )
    else:
        print(
            f"{RED}Аккаунт не найден.{RESET}"
        )

    input("Enter...")


def toggle_account_menu():
    account_id = input(
        "ID аккаунта: "
    ).strip()

    if not account_id.isdigit():
        return

    if toggle_account(
        int(account_id)
    ):
        print(
            f"{GREEN}✓ Статус изменён.{RESET}"
        )
    else:
        print(
            f"{RED}Аккаунт не найден.{RESET}"
        )

    input("Enter...")


def delete_all_accounts_menu():
    print()
    print(
        f"{RED}ВНИМАНИЕ: будут удалены ВСЕ аккаунты.{RESET}"
    )

    confirm = input(
        "Введите DELETE ALL: "
    ).strip()

    if confirm == "DELETE ALL":
        delete_all_accounts()

        print(
            f"{GREEN}✓ Все аккаунты удалены.{RESET}"
        )
    else:
        print("Отменено.")

    input("Enter...")


# ══════════════════════════════════════════════════════════════════════════════
# REMNAWAVE MENU
# ══════════════════════════════════════════════════════════════════════════════

def remnawave_menu():
    while True:
        clear()
        header("Remnawave")

        if remnawave_enabled():
            print(
                f"{GREEN}✓ Интеграция включена{RESET}"
            )

            print(
                f"Panel: "
                f"{get_state('remnawave_url')}"
            )

            print(
                f"Host UUID: "
                f"{get_state('remnawave_host_uuid')}"
            )

        else:
            print(
                f"{GRAY}Интеграция не настроена.{RESET}"
            )

        print()
        print("  1. Настроить / изменить")
        print("  2. Показать текущий Host")
        print("  3. Отключить интеграцию")
        print("  0. Назад")
        print()

        choice = input(
            "Выберите действие: "
        ).strip()

        if choice == "1":
            setup_remnawave()
            input("Enter...")

        elif choice == "2":
            host = get_remnawave_host()

            if host:
                show_host(host)
            else:
                print(
                    f"{RED}Не удалось получить Host.{RESET}"
                )

            input("Enter...")

        elif choice == "3":
            for key in [
                "remnawave_url",
                "remnawave_token",
                "remnawave_host_uuid",
                "remnawave_configured"
            ]:
                delete_state(key)

            print(
                f"{GREEN}✓ Remnawave отключён.{RESET}"
            )

            input("Enter...")

        elif choice == "0":
            return


# ══════════════════════════════════════════════════════════════════════════════
# MONITOR
# ══════════════════════════════════════════════════════════════════════════════

def monitor():
    if not check_config():
        log(
            "Конфигурация не заполнена."
        )
        sys.exit(1)

    log(
        "Монитор запущен."
    )

    log(
        f"Слежу за: "
        f"{get_state('current_cdn_domain')}"
    )

    fail_count = 0

    while True:
        try:
            domain = get_state(
                "current_cdn_domain"
            )

            if not domain:
                time.sleep(
                    CHECK_INTERVAL
                )
                continue

            purge_at = get_state(
                "purge_at"
            )

            if purge_at:
                try:
                    if float(purge_at) < time.time():
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
                                    "✗ Ошибка очистки кеша"
                                )

                        set_state(
                            "purge_at",
                            ""
                        )

                except Exception:
                    pass

            if check_cdn_domain(domain):
                if fail_count:
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
                    f"{domain}"
                )

                if fail_count >= FAIL_THRESHOLD:
                    new_domain = do_failover()

                    if new_domain:
                        log(
                            f"Переключились на: "
                            f"{new_domain}"
                        )

                        fail_count = 0

            time.sleep(
                CHECK_INTERVAL
            )

        except KeyboardInterrupt:
            break

        except Exception as e:
            log(
                f"Ошибка мониторинга: {e}"
            )

            time.sleep(
                CHECK_INTERVAL
            )


# ══════════════════════════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════════════════════════

def uninstall():
    clear()
    header("Удаление Beeline CDN Failover")

    print(
        f"{RED}ВНИМАНИЕ!{RESET}"
    )

    print(
        "Будут удалены:"
    )

    print(
        f"  - systemd service"
    )

    print(
        f"  - /opt/cdn_monitor"
    )

    print(
        "  - база аккаунтов"
    )

    print(
        "  - сохранённые настройки"
    )

    print()

    confirm = input(
        "Введите DELETE для полного удаления: "
    ).strip()

    if confirm != "DELETE":
        print("Отменено.")
        return

    os.system(
        "systemctl stop beeline-failover "
        "2>/dev/null || true"
    )

    os.system(
        "systemctl disable beeline-failover "
        "2>/dev/null || true"
    )

    service_file = (
        "/etc/systemd/system/"
        "beeline-failover.service"
    )

    try:
        if os.path.exists(service_file):
            os.remove(service_file)
    except Exception:
        pass

    os.system(
        "systemctl daemon-reload"
    )

    import shutil

    try:
        shutil.rmtree(
            "/opt/cdn_monitor"
        )
    except Exception:
        pass

    print()
    print(
        f"{GREEN}✓ Beeline CDN Failover полностью удалён.{RESET}"
    )


# ══════════════════════════════════════════════════════════════════════════════
# MENU
# ══════════════════════════════════════════════════════════════════════════════

def menu():
    while True:
        clear()
        header()

        configured = check_config()

        print(
            f"  CDN: "
            f"{get_state('current_cdn_domain', 'не настроен')}"
        )

        if remnawave_enabled():
            print(
                f"  Remnawave: "
                f"{GREEN}ON{RESET}"
            )
        else:
            print(
                f"  Remnawave: "
                f"{GRAY}OFF{RESET}"
            )

        print()

        print(
            f"{CYAN}── Управление ──{RESET}"
        )

        print()
        print("  1. Первичная настройка")
        print("  2. Аккаунты Beeline CDN")
        print("  3. Remnawave")
        print("  4. Статус")
        print("  5. Проверить CDN сейчас")
        print("  6. Запустить systemd")
        print("  7. Остановить systemd")
        print("  8. Перезапустить systemd")
        print("  9. Показать логи")
        print("  10. Удалить программу")
        print("  0. Выход")
        print()

        choice = input(
            "Выберите действие: "
        ).strip()

        if choice == "1":
            clear()
            header("Первичная настройка")

            setup_main()

            input(
                "\nНажмите Enter..."
            )

        elif choice == "2":
            accounts_menu()

        elif choice == "3":
            remnawave_menu()

        elif choice == "4":
            status()

            input(
                "Enter..."
            )

        elif choice == "5":
            domain = get_state(
                "current_cdn_domain"
            )

            print()

            if not domain:
                print(
                    f"{RED}CDN домен не настроен.{RESET}"
                )
            else:
                print(
                    f"Проверяем {domain}..."
                )

                if check_cdn_domain(domain):
                    print(
                        f"{GREEN}✓ CDN доступен{RESET}"
                    )
                else:
                    print(
                        f"{RED}✗ CDN недоступен{RESET}"
                    )

            input(
                "Enter..."
            )

        elif choice == "6":
            os.system(
                "systemctl start "
                "beeline-failover"
            )

            print(
                f"{GREEN}✓ Монитор запущен.{RESET}"
            )

            input(
                "Enter..."
            )

        elif choice == "7":
            os.system(
                "systemctl stop "
                "beeline-failover"
            )

            print(
                f"{YELLOW}✓ Монитор остановлен.{RESET}"
            )

            input(
                "Enter..."
            )

        elif choice == "8":
            os.system(
                "systemctl restart "
                "beeline-failover"
            )

            print(
                f"{GREEN}✓ Монитор перезапущен.{RESET}"
            )

            input(
                "Enter..."
            )

        elif choice == "9":
            os.system(
                "journalctl "
                "-u beeline-failover "
                "--no-pager "
                "-n 50"
            )

            print()

            input(
                "Enter..."
            )

        elif choice == "10":
            uninstall()
            return

        elif choice == "0":
            return


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    urllib3.disable_warnings(
        urllib3.exceptions.InsecureRequestWarning
    )

    init_db()

    if len(sys.argv) > 1:
        command = sys.argv[1].lower()

        if command == "setup":
            setup_main()

        elif command == "remnawave":
            setup_remnawave()

        elif command == "status":
            status()

        elif command == "monitor":
            monitor()

        elif command == "check-config":
            sys.exit(
                0 if check_config() else 1
            )

        elif command == "menu":
            menu()

        else:
            print(
                "Неизвестная команда."
            )

        return

    menu()


if __name__ == "__main__":
    main()
