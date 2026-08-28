#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="Beeline CDN Failover"

APP_DIR="/opt/cdn_monitor"
APP_FILE="${APP_DIR}/cdn_monitor.py"
VENV_DIR="${APP_DIR}/venv"

SERVICE_NAME="beeline-failover"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

RAW_BASE="https://raw.githubusercontent.com/vozduh443/Beeline-Failover/main"
PYTHON_URL="${RAW_BASE}/cdn_monitor.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
RESET='\033[0m'


info() {
    echo -e "${CYAN}[*]${RESET} $1"
}

ok() {
    echo -e "${GREEN}[✓]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $1"
}

fail() {
    echo -e "${RED}[✗]${RESET} $1"
    exit 1
}


cleanup() {
    rm -f "${TMP_FILE:-}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'echo -e "\n${RED}[✗] Установка прервана.${RESET}"; exit 1' INT TERM


# ══════════════════════════════════════════════════════════════════════════════
# ROOT
# ══════════════════════════════════════════════════════════════════════════════

if [[ "${EUID}" -ne 0 ]]; then
    fail "Запустите установщик от root."
fi


# ══════════════════════════════════════════════════════════════════════════════
# TTY
# ══════════════════════════════════════════════════════════════════════════════

if [[ ! -r /dev/tty ]]; then
    fail "Не удалось открыть /dev/tty."
fi


# ══════════════════════════════════════════════════════════════════════════════
# HEADER
# ══════════════════════════════════════════════════════════════════════════════

clear 2>/dev/null || true

echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║                                                        ║${RESET}"
echo -e "${CYAN}║       ${WHITE}🐝 Beeline CDN Failover Installer${RESET}          ${CYAN}║${RESET}"
echo -e "${CYAN}║                                                        ║${RESET}"
echo -e "${CYAN}║       ${WHITE}Automatic CDN failover & Remnawave${RESET}         ${CYAN}║${RESET}"
echo -e "${CYAN}║                                                        ║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${GRAY}GitHub: github.com/vozduh443/Beeline-Failover${RESET}"
echo


# ══════════════════════════════════════════════════════════════════════════════
# OS
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Проверка системы ━━━${RESET}"
echo

if [[ ! -f /etc/os-release ]]; then
    fail "Не удалось определить операционную систему."
fi

source /etc/os-release

info "ОС: ${PRETTY_NAME:-$ID}"


case "${ID}" in

    ubuntu|debian)

        export DEBIAN_FRONTEND=noninteractive

        info "Обновляем список пакетов..."

        apt-get update -qq

        info "Устанавливаем зависимости..."

        apt-get install -y -qq \
            curl \
            ca-certificates \
            python3 \
            python3-pip \
            python3-venv \
            > /dev/null

        ok "Системные зависимости установлены"

        ;;

    *)

        warn "ОС ${ID} не входит в список протестированных."

        command -v curl >/dev/null 2>&1 || \
            fail "Не найден curl."

        command -v python3 >/dev/null 2>&1 || \
            fail "Не найден python3."

        python3 -m venv --help >/dev/null 2>&1 || \
            fail "Не найден python3-venv."

        ;;

esac


PYTHON_BIN="$(command -v python3)"

info "Python: $(${PYTHON_BIN} --version 2>&1)"


# ══════════════════════════════════════════════════════════════════════════════
# APPLICATION
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Установка приложения ━━━${RESET}"
echo

mkdir -p "${APP_DIR}"
chmod 755 "${APP_DIR}"

ok "Каталог ${APP_DIR} создан"


# ══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD PYTHON
# ══════════════════════════════════════════════════════════════════════════════

info "Скачиваем cdn_monitor.py..."

TMP_FILE="$(mktemp)"

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 60 \
    "${PYTHON_URL}?nocache=$(date +%s)" \
    -o "${TMP_FILE}" || \
    fail "Не удалось скачать cdn_monitor.py."


if [[ ! -s "${TMP_FILE}" ]]; then
    fail "cdn_monitor.py пустой."
fi


if ! head -n 1 "${TMP_FILE}" | grep -q "python3"; then

    echo
    echo -e "${RED}Первые строки скачанного файла:${RESET}"
    head -n 15 "${TMP_FILE}" || true
    echo

    fail "GitHub вернул файл, который не похож на Python-скрипт."
fi


install -m 755 "${TMP_FILE}" "${APP_FILE}"

rm -f "${TMP_FILE}"

ok "cdn_monitor.py установлен"


# ══════════════════════════════════════════════════════════════════════════════
# VIRTUALENV
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Python окружение ━━━${RESET}"
echo

if [[ ! -d "${VENV_DIR}" ]]; then

    info "Создаём virtualenv..."

    "${PYTHON_BIN}" -m venv "${VENV_DIR}" || \
        fail "Не удалось создать virtualenv."

    ok "Virtualenv создан"

else

    ok "Virtualenv уже существует"

fi


VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"


info "Устанавливаем Python-зависимости..."

"${VENV_PIP}" install \
    --disable-pip-version-check \
    --quiet \
    --upgrade pip


"${VENV_PIP}" install \
    --disable-pip-version-check \
    --quiet \
    requests \
    urllib3


ok "requests и urllib3 установлены"


# ══════════════════════════════════════════════════════════════════════════════
# PYTHON CHECK
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Проверка Python-кода ━━━${RESET}"
echo

"${VENV_PYTHON}" -m py_compile "${APP_FILE}" || \
    fail "Ошибка синтаксиса в cdn_monitor.py."

ok "Python-код корректен"


# ══════════════════════════════════════════════════════════════════════════════
# DATABASE
# ══════════════════════════════════════════════════════════════════════════════

info "Инициализируем базу данных..."

"${VENV_PYTHON}" -c '
import sys
sys.path.insert(0, "/opt/cdn_monitor")

import cdn_monitor

cdn_monitor.init_db()
'

ok "База данных готова"


# ══════════════════════════════════════════════════════════════════════════════
# SYSTEMD
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Systemd ━━━${RESET}"
echo


cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=${APP_NAME}
Documentation=https://github.com/vozduh443/Beeline-Failover
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

WorkingDirectory=${APP_DIR}

ExecStart=${VENV_PYTHON} ${APP_FILE} monitor

Restart=always
RestartSec=5

User=root
Group=root

Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload

systemctl enable "${SERVICE_NAME}" >/dev/null

ok "Systemd service создан"
ok "Автозапуск включён"


# ══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE SETUP
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Первичная настройка ━━━${RESET}"
echo

echo -e "${CYAN}Введите параметры основной CDN-конфигурации.${RESET}"
echo -e "${GRAY}Ввод выполняется непосредственно через терминал.${RESET}"
echo


# ──────────────────────────────────────────────────────────────────────────────
# SOURCE IP
# ──────────────────────────────────────────────────────────────────────────────

while true; do

    printf "IP источника: " > /dev/tty

    IFS= read -r SOURCE_IP < /dev/tty

    SOURCE_IP="${SOURCE_IP#"${SOURCE_IP%%[![:space:]]*}"}"
    SOURCE_IP="${SOURCE_IP%"${SOURCE_IP##*[![:space:]]}"}"

    if [[ -n "${SOURCE_IP}" ]]; then
        break
    fi

    echo -e "${RED}IP источника не может быть пустым.${RESET}" > /dev/tty

done


# ──────────────────────────────────────────────────────────────────────────────
# HOSTNAME
# ──────────────────────────────────────────────────────────────────────────────

while true; do

    printf "Origin Hostname / Host: " > /dev/tty

    IFS= read -r HOSTNAME < /dev/tty

    HOSTNAME="${HOSTNAME#"${HOSTNAME%%[![:space:]]*}"}"
    HOSTNAME="${HOSTNAME%"${HOSTNAME##*[![:space:]]}"}"

    if [[ -n "${HOSTNAME}" ]]; then
        break
    fi

    echo -e "${RED}Hostname не может быть пустым.${RESET}" > /dev/tty

done


# ──────────────────────────────────────────────────────────────────────────────
# SNI
# ──────────────────────────────────────────────────────────────────────────────

printf "SNI [%s]: " "${HOSTNAME}" > /dev/tty

IFS= read -r SNI_HOSTNAME < /dev/tty

SNI_HOSTNAME="${SNI_HOSTNAME#"${SNI_HOSTNAME%%[![:space:]]*}"}"
SNI_HOSTNAME="${SNI_HOSTNAME%"${SNI_HOSTNAME##*[![:space:]]}"}"

if [[ -z "${SNI_HOSTNAME}" ]]; then
    SNI_HOSTNAME="${HOSTNAME}"
fi


# ──────────────────────────────────────────────────────────────────────────────
# CURRENT CDN DOMAIN
# ──────────────────────────────────────────────────────────────────────────────

while true; do

    printf "Текущий CDN тех-домен: " > /dev/tty

    IFS= read -r CDN_DOMAIN < /dev/tty

    CDN_DOMAIN="${CDN_DOMAIN#"${CDN_DOMAIN%%[![:space:]]*}"}"
    CDN_DOMAIN="${CDN_DOMAIN%"${CDN_DOMAIN##*[![:space:]]}"}"

    if [[ -n "${CDN_DOMAIN}" ]]; then
        break
    fi

    echo -e "${RED}CDN тех-домен не может быть пустым.${RESET}" > /dev/tty

done


# ══════════════════════════════════════════════════════════════════════════════
# SAVE MAIN CONFIG
# ══════════════════════════════════════════════════════════════════════════════

"${VENV_PYTHON}" - "${SOURCE_IP}" "${HOSTNAME}" "${SNI_HOSTNAME}" "${CDN_DOMAIN}" <<'PY'
import sys
import sqlite3

db_path = "/opt/cdn_monitor/accounts.db"

source_ip = sys.argv[1]
hostname = sys.argv[2]
sni = sys.argv[3]
cdn_domain = sys.argv[4]

conn = sqlite3.connect(db_path)

values = {
    "source_ip": source_ip,
    "hostname": hostname,
    "sni_hostname": sni,
    "current_cdn_domain": cdn_domain
}

for key, value in values.items():
    conn.execute(
        """
        INSERT OR REPLACE INTO state(key,value)
        VALUES(?,?)
        """,
        (key, value)
    )

conn.commit()
conn.close()
PY


ok "Основная конфигурация сохранена"


# ══════════════════════════════════════════════════════════════════════════════
# REMNAWAVE
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Remnawave ━━━${RESET}"
echo


printf "Настроить Remnawave сейчас? [Y/n]: " > /dev/tty

IFS= read -r RW_ENABLE < /dev/tty

RW_ENABLE="${RW_ENABLE,,}"

if [[ "${RW_ENABLE}" != "n" && "${RW_ENABLE}" != "no" && "${RW_ENABLE}" != "н" && "${RW_ENABLE}" != "нет" ]]; then

    echo
    echo -e "${CYAN}Введите параметры Remnawave.${RESET}"
    echo


    # ──────────────────────────────────────────────────────────────────────────
    # PANEL URL
    # ──────────────────────────────────────────────────────────────────────────

    while true; do

        printf "Panel URL (например https://panel.example.com): " > /dev/tty

        IFS= read -r RW_URL < /dev/tty

        RW_URL="${RW_URL#"${RW_URL%%[![:space:]]*}"}"
        RW_URL="${RW_URL%"${RW_URL##*[![:space:]]}"}"

        RW_URL="${RW_URL%/}"

        if [[ -n "${RW_URL}" ]]; then
            break
        fi

        echo -e "${RED}URL не может быть пустым.${RESET}" > /dev/tty

    done


    # ──────────────────────────────────────────────────────────────────────────
    # API TOKEN
    # ──────────────────────────────────────────────────────────────────────────

    printf "API Token: " > /dev/tty

    IFS= read -r RW_TOKEN < /dev/tty


    while [[ -z "${RW_TOKEN}" ]]; do

        echo -e "${RED}Token не может быть пустым.${RESET}" > /dev/tty

        printf "API Token: " > /dev/tty

        IFS= read -r RW_TOKEN < /dev/tty

    done


    # ──────────────────────────────────────────────────────────────────────────
    # HOST UUID
    # ──────────────────────────────────────────────────────────────────────────

    while true; do

        printf "UUID Host: " > /dev/tty

        IFS= read -r RW_HOST_UUID < /dev/tty

        RW_HOST_UUID="${RW_HOST_UUID#"${RW_HOST_UUID%%[![:space:]]*}"}"
        RW_HOST_UUID="${RW_HOST_UUID%"${RW_HOST_UUID##*[![:space:]]}"}"

        if [[ -n "${RW_HOST_UUID}" ]]; then
            break
        fi

        echo -e "${RED}UUID Host не может быть пустым.${RESET}" > /dev/tty

    done


    # ──────────────────────────────────────────────────────────────────────────
    # SAVE REMNAWAVE CONFIG
    # ──────────────────────────────────────────────────────────────────────────

    "${VENV_PYTHON}" - \
        "${RW_URL}" \
        "${RW_TOKEN}" \
        "${RW_HOST_UUID}" <<'PY'

import sys
import sqlite3

db_path = "/opt/cdn_monitor/accounts.db"

url = sys.argv[1]
token = sys.argv[2]
host_uuid = sys.argv[3]

conn = sqlite3.connect(db_path)

values = {
    "remnawave_url": url,
    "remnawave_token": token,
    "remnawave_host_uuid": host_uuid,
    "remnawave_configured": "1"
}

for key, value in values.items():
    conn.execute(
        """
        INSERT OR REPLACE INTO state(key,value)
        VALUES(?,?)
        """,
        (key, value)
    )

conn.commit()
conn.close()
PY


    ok "Данные Remnawave сохранены"


    # ══════════════════════════════════════════════════════════════════════════
    # GET HOST
    # ══════════════════════════════════════════════════════════════════════════

    echo
    info "Получаем текущий Host из Remnawave..."


    "${VENV_PYTHON}" - "${RW_URL}" "${RW_TOKEN}" "${RW_HOST_UUID}" <<'PY'

import sys
import requests
import sqlite3
import urllib3

urllib3.disable_warnings()

url = sys.argv[1].rstrip("/")
token = sys.argv[2]
uuid = sys.argv[3]

try:

    r = requests.get(
        f"{url}/api/hosts/{uuid}",
        headers={
            "Authorization": f"Bearer {token}"
        },
        verify=False,
        timeout=15
    )

    if r.status_code != 200:
        print(
            f"Remnawave вернул HTTP {r.status_code}"
        )
        print(r.text[:1000])
        sys.exit(1)

    data = r.json()

    host = data.get("response", data)

    if not isinstance(host, dict):
        print("Некорректный ответ Remnawave.")
        sys.exit(1)

    extra = host.get("xhttpExtraParams") or {}
    headers = extra.get("headers") or {}

    values = {
        "host_address": host.get("address", ""),
        "host_sni": host.get("sni", ""),
        "host_host": host.get("host", ""),
        "host_path": host.get("path", ""),
        "host_origin": headers.get("Origin", ""),
        "host_referer": headers.get("Referer", "")
    }

    print()
    print("Remnawave Host:")
    print()
    print("  Address :", values["host_address"])
    print("  SNI     :", values["host_sni"])
    print("  Host    :", values["host_host"])
    print("  Path    :", values["host_path"])
    print("  Origin  :", values["host_origin"])
    print("  Referer :", values["host_referer"])
    print()

    conn = sqlite3.connect("/opt/cdn_monitor/accounts.db")

    for key, value in values.items():
        conn.execute(
            """
            INSERT OR REPLACE INTO state(key,value)
            VALUES(?,?)
            """,
            (key, value)
        )

    conn.commit()
    conn.close()

except Exception as e:

    print(
        f"Ошибка получения Host: {e}"
    )

    sys.exit(1)

PY


    if [[ "$?" -eq 0 ]]; then
        ok "Host Remnawave получен"
    else
        warn "Не удалось получить Host Remnawave."
        warn "Интеграция сохранена, проверить можно позже через меню."
    fi

else

    info "Интеграция Remnawave пропущена."

fi


# ══════════════════════════════════════════════════════════════════════════════
# CONFIG CHECK
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Проверка конфигурации ━━━${RESET}"
echo


if "${VENV_PYTHON}" "${APP_FILE}" check-config; then

    ok "Конфигурация корректна"

else

    warn "Конфигурация не прошла проверку."
    warn "Мониторинг пока не запускается."

fi


# ══════════════════════════════════════════════════════════════════════════════
# START
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${WHITE}━━━ Запуск ━━━${RESET}"
echo


if "${VENV_PYTHON}" "${APP_FILE}" check-config >/dev/null 2>&1; then

    systemctl restart "${SERVICE_NAME}"

    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then

        ok "Beeline CDN Failover запущен"

    else

        echo
        echo -e "${RED}Последние строки журнала:${RESET}"
        echo

        journalctl \
            -u "${SERVICE_NAME}" \
            --no-pager \
            -n 30 || true

        fail "Сервис не запустился."

    fi

else

    warn "Сервис установлен, но не запущен."
    warn "Исправьте конфигурацию и запустите его вручную."

fi


# ══════════════════════════════════════════════════════════════════════════════
# FINISH
# ══════════════════════════════════════════════════════════════════════════════

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}              ${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА${RESET}              ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo

echo -e "${WHITE}Приложение:${RESET} ${APP_DIR}"
echo -e "${WHITE}Python:${RESET}     ${APP_FILE}"
echo -e "${WHITE}Virtualenv:${RESET}  ${VENV_DIR}"
echo -e "${WHITE}База:${RESET}        ${APP_DIR}/accounts.db"
echo -e "${WHITE}Лог:${RESET}         ${APP_DIR}/monitor.log"
echo -e "${WHITE}Service:${RESET}    ${SERVICE_NAME}"
echo

echo -e "${CYAN}━━━ Управление ━━━${RESET}"
echo

echo "  ${VENV_PYTHON} ${APP_FILE}"
echo

echo "  systemctl status ${SERVICE_NAME}"
echo

echo "  journalctl -u ${SERVICE_NAME} -f"
echo

echo "  systemctl restart ${SERVICE_NAME}"
echo

echo -e "${GREEN}Автозапуск включён.${RESET}"
echo
