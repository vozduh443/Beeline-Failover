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

echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}       ${WHITE}🐝 Beeline CDN Failover Installer${RESET}          ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}       Automatic CDN failover & Remnawave             ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${GRAY}GitHub: github.com/vozduh443/Beeline-Failover${RESET}"
echo

if [[ "${EUID}" -ne 0 ]]; then
    fail "Запустите установщик от root."
fi

info "Проверяем операционную систему..."

if [[ ! -f /etc/os-release ]]; then
    fail "Не удалось определить операционную систему."
fi

source /etc/os-release

ok "ОС: ${PRETTY_NAME:-$ID}"

if [[ "${ID}" == "debian" || "${ID}" == "ubuntu" ]]; then

    info "Обновляем список пакетов..."

    export DEBIAN_FRONTEND=noninteractive

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

else

    warn "Автоматическая установка пакетов поддерживается только для Debian/Ubuntu."

    command -v curl >/dev/null 2>&1 || \
        fail "curl не установлен."

    command -v python3 >/dev/null 2>&1 || \
        fail "python3 не установлен."

    command -v python3 -m venv >/dev/null 2>&1 || \
        true
fi

PYTHON_BIN="$(command -v python3)"

info "Python: $(${PYTHON_BIN} --version 2>&1)"

echo
echo -e "${WHITE}━━━ Установка приложения ━━━${RESET}"
echo

mkdir -p "${APP_DIR}"

chmod 755 "${APP_DIR}"

ok "Каталог ${APP_DIR} создан"

info "Скачиваем cdn_monitor.py..."

TMP_FILE="$(mktemp)"

trap 'rm -f "${TMP_FILE}"' EXIT

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 60 \
    "${PYTHON_URL}" \
    -o "${TMP_FILE}" || \
    fail "Не удалось скачать cdn_monitor.py."

if [[ ! -s "${TMP_FILE}" ]]; then
    fail "cdn_monitor.py пустой."
fi

install -m 755 "${TMP_FILE}" "${APP_FILE}"

ok "cdn_monitor.py установлен"

echo
echo -e "${WHITE}━━━ Python окружение ━━━${RESET}"
echo

if [[ ! -d "${VENV_DIR}" ]]; then

    info "Создаём virtualenv..."

    "${PYTHON_BIN}" -m venv "${VENV_DIR}" || \
        fail "Не удалось создать Python virtualenv."

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

echo
echo -e "${WHITE}━━━ Проверка Python-кода ━━━${RESET}"
echo

"${VENV_PYTHON}" -m py_compile "${APP_FILE}" || \
    fail "Ошибка синтаксиса в cdn_monitor.py."

ok "Python-код корректен"

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

ok "Systemd service создан"

systemctl daemon-reload

systemctl enable "${SERVICE_NAME}" >/dev/null

ok "Автозапуск включён"

echo
echo -e "${WHITE}━━━ Запуск ━━━${RESET}"
echo

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

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}              ${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА${RESET}              ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo

echo -e "${WHITE}Приложение:${RESET} ${APP_DIR}"
echo -e "${WHITE}Python:${RESET}     ${APP_FILE}"
echo -e "${WHITE}База:${RESET}       ${APP_DIR}/accounts.db"
echo -e "${WHITE}Лог:${RESET}        ${APP_DIR}/monitor.log"
echo -e "${WHITE}Service:${RESET}    ${SERVICE_NAME}"
echo

echo -e "${CYAN}Команды:${RESET}"
echo
echo "  Настройка:"
echo "    ${VENV_PYTHON} ${APP_FILE} setup"
echo
echo "  Добавить аккаунт:"
echo "    ${VENV_PYTHON} ${APP_FILE} add"
echo
echo "  Настроить Remnawave:"
echo "    ${VENV_PYTHON} ${APP_FILE} remnawave"
echo
echo "  Статус:"
echo "    ${VENV_PYTHON} ${APP_FILE} status"
echo
echo "  Systemd:"
echo "    systemctl status ${SERVICE_NAME}"
echo
echo "  Логи:"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo

echo -e "${GREEN}Мониторинг запущен автоматически.${RESET}"
echo
