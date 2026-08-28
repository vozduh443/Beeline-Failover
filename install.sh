#!/usr/bin/env bash

set -Eeuo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Beeline CDN Failover — Installer
# https://github.com/vozduh443/Beeline-Failover
# ══════════════════════════════════════════════════════════════════════════════

APP_NAME="Beeline CDN Failover"
APP_DIR="/opt/cdn_monitor"
APP_FILE="${APP_DIR}/cdn_monitor.py"
SERVICE_NAME="beeline-failover"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

REPO_RAW="https://raw.githubusercontent.com/vozduh443/Beeline-Failover/main"
PYTHON_URL="${REPO_RAW}/cdn_monitor.py"

# ─────────────────────────────────────────────────────────────────────────────
# Цвета
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    GRAY=''
    RESET=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# Служебные функции
# ─────────────────────────────────────────────────────────────────────────────

info() {
    echo -e "${CYAN}[*]${RESET} $1"
}

success() {
    echo -e "${GREEN}[✓]${RESET} $1"
}

warning() {
    echo -e "${YELLOW}[!]${RESET} $1"
}

error() {
    echo -e "${RED}[✗]${RESET} $1" >&2
}

die() {
    error "$1"
    exit 1
}

step() {
    echo
    echo -e "${WHITE}━━━ $1 ━━━${RESET}"
}

cleanup() {
    :
}

trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Баннер
# ─────────────────────────────────────────────────────────────────────────────

clear 2>/dev/null || true

echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}       ${WHITE}🐝 Beeline CDN Failover Installer${RESET}          ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}       Automatic CDN failover & Remnawave             ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}       integration                                     ${CYAN}║${RESET}"
echo -e "${CYAN}║${RESET}                                                        ${CYAN}║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${GRAY}GitHub: github.com/vozduh443/Beeline-Failover${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Проверка root
# ─────────────────────────────────────────────────────────────────────────────

step "Проверка системы"

if [[ "${EUID}" -ne 0 ]]; then
    die "Запустите установщик от root."
fi

success "Права root подтверждены"

# ─────────────────────────────────────────────────────────────────────────────
# Определение ОС
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
else
    die "Не удалось определить операционную систему."
fi

OS_ID="${ID:-unknown}"
OS_NAME="${PRETTY_NAME:-${OS_ID}}"

info "ОС: ${OS_NAME}"

case "${OS_ID}" in
    debian|ubuntu)
        PACKAGE_MANAGER="apt-get"
        ;;
    *)
        warning "ОС не входит в список протестированных: ${OS_ID}"
        warning "Продолжаем установку, но автоматическая установка пакетов может отличаться."
        PACKAGE_MANAGER=""
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Установка зависимостей
# ─────────────────────────────────────────────────────────────────────────────

step "Проверка зависимостей"

install_debian_packages() {
    export DEBIAN_FRONTEND=noninteractive

    info "Обновление списка пакетов..."
    apt-get update -qq

    info "Установка системных зависимостей..."

    apt-get install -y -qq \
        curl \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
        > /dev/null

    success "Системные зависимости установлены"
}

if [[ -n "${PACKAGE_MANAGER}" ]]; then
    if ! command -v python3 >/dev/null 2>&1 || \
       ! command -v curl >/dev/null 2>&1; then

        install_debian_packages
    else
        success "Python 3 и curl уже установлены"
    fi
else
    command -v python3 >/dev/null 2>&1 || \
        die "Python 3 не найден. Установите Python 3 вручную."

    command -v curl >/dev/null 2>&1 || \
        die "curl не найден. Установите curl вручную."

    success "Python 3 и curl найдены"
fi

PYTHON_BIN="$(command -v python3)"

PYTHON_VERSION="$(
    "${PYTHON_BIN}" --version 2>&1
)"

info "${PYTHON_VERSION}"

# ─────────────────────────────────────────────────────────────────────────────
# Создание директории
# ─────────────────────────────────────────────────────────────────────────────

step "Установка приложения"

mkdir -p "${APP_DIR}"

chmod 755 "${APP_DIR}"

success "Каталог ${APP_DIR} создан"

# ─────────────────────────────────────────────────────────────────────────────
# Скачивание Python-приложения
# ─────────────────────────────────────────────────────────────────────────────

info "Скачивание cdn_monitor.py..."

TMP_FILE="$(mktemp)"

if ! curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 15 \
    --max-time 60 \
    "${PYTHON_URL}" \
    -o "${TMP_FILE}"; then

    rm -f "${TMP_FILE}"
    die "Не удалось скачать cdn_monitor.py с GitHub."
fi

if [[ ! -s "${TMP_FILE}" ]]; then
    rm -f "${TMP_FILE}"
    die "Скачанный cdn_monitor.py пустой."
fi

if ! head -n 1 "${TMP_FILE}" | grep -q "python3"; then
    rm -f "${TMP_FILE}"
    die "GitHub вернул файл, который не похож на Python-скрипт."
fi

install -m 755 "${TMP_FILE}" "${APP_FILE}"

rm -f "${TMP_FILE}"

success "cdn_monitor.py установлен"

# ─────────────────────────────────────────────────────────────────────────────
# Python virtualenv
# ─────────────────────────────────────────────────────────────────────────────

info "Создание Python virtualenv..."

VENV_DIR="${APP_DIR}/venv"

if [[ ! -d "${VENV_DIR}" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

success "Virtualenv создан"

# ─────────────────────────────────────────────────────────────────────────────
# Python-зависимости
# ─────────────────────────────────────────────────────────────────────────────

info "Установка Python-зависимостей..."

"${VENV_PIP}" install \
    --disable-pip-version-check \
    --quiet \
    --upgrade pip

"${VENV_PIP}" install \
    --disable-pip-version-check \
    --quiet \
    requests \
    urllib3

success "Python-зависимости установлены"

# ─────────────────────────────────────────────────────────────────────────────
# Права
# ─────────────────────────────────────────────────────────────────────────────

chmod 755 "${APP_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Systemd
# ─────────────────────────────────────────────────────────────────────────────

step "Настройка автозапуска"

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

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

success "Systemd service создан"

# ─────────────────────────────────────────────────────────────────────────────
# Активация сервиса
# ─────────────────────────────────────────────────────────────────────────────

systemctl daemon-reload

systemctl enable "${SERVICE_NAME}" >/dev/null

success "Автозапуск включён"

# ─────────────────────────────────────────────────────────────────────────────
# Проверка Python-файла
# ─────────────────────────────────────────────────────────────────────────────

step "Проверка приложения"

if ! "${VENV_PYTHON}" -m py_compile "${APP_FILE}"; then
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    die "Ошибка синтаксиса в cdn_monitor.py."
fi

success "Python-код прошёл проверку"

# ─────────────────────────────────────────────────────────────────────────────
# Запуск
# ─────────────────────────────────────────────────────────────────────────────

step "Запуск сервиса"

systemctl restart "${SERVICE_NAME}"

sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "Beeline CDN Failover успешно запущен"
else
    error "Сервис не запустился."

    echo
    echo -e "${YELLOW}Последние строки журнала:${RESET}"
    journalctl \
        -u "${SERVICE_NAME}" \
        --no-pager \
        -n 30 || true

    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Финальная информация
# ─────────────────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}              ${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА${RESET}              ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo

echo -e "${WHITE}Приложение:${RESET} ${APP_DIR}"
echo -e "${WHITE}Конфиг/БД:${RESET}   ${APP_DIR}/accounts.db"
echo -e "${WHITE}Лог:${RESET}         ${APP_DIR}/monitor.log"
echo -e "${WHITE}Сервис:${RESET}      ${SERVICE_NAME}"
echo

echo -e "${CYAN}Следующие команды:${RESET}"
echo
echo -e "  ${WHITE}Настройка:${RESET}"
echo "    ${VENV_PYTHON} ${APP_FILE} setup"
echo
echo -e "  ${WHITE}Добавить аккаунт:${RESET}"
echo "    ${VENV_PYTHON} ${APP_FILE} add"
echo
echo -e "  ${WHITE}Статус:${RESET}"
echo "    ${VENV_PYTHON} ${APP_FILE} status"
echo
echo -e "  ${WHITE}Статус systemd:${RESET}"
echo "    systemctl status ${SERVICE_NAME}"
echo
echo -e "  ${WHITE}Логи:${RESET}"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo

echo -e "${GREEN}Мониторинг запущен и будет автоматически стартовать после перезагрузки.${RESET}"
echo
