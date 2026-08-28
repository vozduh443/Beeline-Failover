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
BLUE='\033[0;34m'
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

trap 'echo -e "\n${RED}[✗] Установка прервана.${RESET}"' INT TERM

clear 2>/dev/null || true

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
        warn "Продолжаем установку."

        command -v curl >/dev/null 2>&1 || \
            fail "Не найден curl."

        command -v python3 >/dev/null 2>&1 || \
            fail "Не найден python3."

        if ! python3 -m venv --help >/dev/null 2>&1; then
            fail "Не найден модуль python3-venv."
        fi
        ;;
esac

PYTHON_BIN="$(command -v python3)"

info "Python: $(${PYTHON_BIN} --version 2>&1)"

echo
echo -e "${WHITE}━━━ Установка приложения ━━━${RESET}"
echo

mkdir -p "${APP_DIR}"
chmod 755 "${APP_DIR}"

ok "Каталог ${APP_DIR} создан"

TMP_FILE="$(mktemp)"

info "Скачиваем cdn_monitor.py..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 60 \
    "${PYTHON_URL}?nocache=$(date +%s)" \
    -o "${TMP_FILE}" || {
        rm -f "${TMP_FILE}"
        fail "Не удалось скачать cdn_monitor.py."
    }

if [[ ! -s "${TMP_FILE}" ]]; then
    rm -f "${TMP_FILE}"
    fail "cdn_monitor.py пустой."
fi

if ! head -n 1 "${TMP_FILE}" | grep -q "python3"; then
    rm -f "${TMP_FILE}"
    fail "Скачанный файл не похож на Python-скрипт."
fi

install -m 755 "${TMP_FILE}" "${APP_FILE}"
rm -f "${TMP_FILE}"

ok "cdn_monitor.py установлен"

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

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null

ok "Systemd service создан"
ok "Автозапуск включён"

echo
echo -e "${WHITE}━━━ Первичная настройка ━━━${RESET}"
echo

echo -e "${CYAN}Сейчас будет выполнена первичная настройка.${RESET}"
echo

"${VENV_PYTHON}" "${APP_FILE}" setup

echo
echo -e "${WHITE}━━━ Проверка конфигурации ━━━${RESET}"
echo

if ! "${VENV_PYTHON}" "${APP_FILE}" check-config; then
    warn "Конфигурация ещё не полностью заполнена."
    warn "Сервис установлен, но запуск мониторинга пропущен."
else
    echo
    echo -e "${WHITE}━━━ Запуск ━━━${RESET}"
    echo

    systemctl restart "${SERVICE_NAME}"

    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Beeline CDN Failover запущен"
    else
        echo
        journalctl \
            -u "${SERVICE_NAME}" \
            --no-pager \
            -n 30 || true

        fail "Сервис не запустился."
    fi
fi

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}              ${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА${RESET}              ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo

echo -e "${WHITE}Приложение:${RESET} ${APP_DIR}"
echo -e "${WHITE}Сервис:${RESET}     ${SERVICE_NAME}"
echo -e "${WHITE}База:${RESET}        ${APP_DIR}/accounts.db"
echo -e "${WHITE}Лог:${RESET}         ${APP_DIR}/monitor.log"
echo

echo -e "${CYAN}Управление:${RESET}"
echo
echo "  ${VENV_PYTHON} ${APP_FILE}"
echo
echo "  systemctl status ${SERVICE_NAME}"
echo
echo "  journalctl -u ${SERVICE_NAME} -f"
echo
