#!/usr/bin/env bash
# menu.sh — единая точка входа: AmneziaWG (docker) + WARP-роутинг + Telegram-бот.
# Запуск: menu   (или bash /root/menu.sh)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/awg2.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/warp.sh"

BOT_DIR="$SCRIPT_DIR/awg-bot"
BOT_PY="$BOT_DIR/bot.py"
ENV_FILE="$BOT_DIR/.env"
SERVICE_FILE="/etc/systemd/system/awg-bot.service"
SERVICE_NAME="awg-bot"

bot_is_installed() {
  [ -f "$SERVICE_FILE" ] && [ -f "$ENV_FILE" ]
}

bot_status_line() {
  if ! bot_is_installed; then
    echo "не установлен"
    return
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "работает"
  else
    echo "остановлен"
  fi
}

bot_install() {
  echo "━━━ Установка Telegram-бота ━━━"
  echo ""
  echo "1. Получи токен бота:"
  echo "   — открой в Telegram @BotFather"
  echo "   — отправь ему команду /newbot"
  echo "   — придумай имя бота (любое) и username (должен заканчиваться на 'bot')"
  echo "   — BotFather пришлёт токен вида 123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  echo ""
  echo "2. Узнай свой Telegram ID:"
  echo "   — открой в Telegram @userinfobot"
  echo "   — отправь ему /start"
  echo "   — он пришлёт число 'Id: ...' — это и есть твой Telegram ID"
  echo ""

  if [ ! -f "$BOT_PY" ]; then
    echo "Не найден $BOT_PY — сначала положи файл бота в $BOT_DIR." >&2
    return 1
  fi

  local token admin_id
  read -rp "Вставь токен бота: " token
  if [ -z "$token" ]; then
    echo "Пустой токен, отмена." >&2
    return 1
  fi
  read -rp "Вставь свой Telegram ID: " admin_id
  if ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
    echo "ID должен быть числом, отмена." >&2
    return 1
  fi

  mkdir -p "$BOT_DIR"
  cat > "$ENV_FILE" <<EOF
BOT_TOKEN=$token
ADMIN_ID=$admin_id
AWG_SH_PATH=$SCRIPT_DIR/awg2.sh
WARP_SH_PATH=$SCRIPT_DIR/warp.sh
EOF
  chmod 600 "$ENV_FILE"

  echo "Проверяю зависимости..."
  if ! command -v pip3 >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq python3-pip >/dev/null
  fi
  pip3 install --break-system-packages -q python-dotenv "python-telegram-bot==21.6"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AmneziaWG + WARP Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=/usr/bin/python3 $BOT_PY
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 2

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Готово: бот запущен. Напиши ему /start в Telegram (с аккаунта с ID $admin_id)."
  else
    echo "Бот не запустился, смотри логи: journalctl -u $SERVICE_NAME -n 50 --no-pager" >&2
    return 1
  fi
}

bot_logs() {
  journalctl -u "$SERVICE_NAME" -n 40 --no-pager
}

bot_menu() {
  while true; do
    echo ""
    echo "=== Telegram-бот ==="
    echo "Статус: $(bot_status_line)"
    if bot_is_installed; then
      echo "1) Перезапустить"
      echo "2) Остановить"
      echo "3) Логи (последние 40 строк)"
      echo "4) Переустановить (новый токен/ID)"
      echo "0) Назад"
      read -rp "Выбор: " ch
      case "$ch" in
        1) systemctl restart "$SERVICE_NAME" && echo "Перезапущен." ;;
        2) systemctl stop "$SERVICE_NAME" && echo "Остановлен." ;;
        3) bot_logs ;;
        4) bot_install ;;
        0) return ;;
        *) echo "Неверный выбор" ;;
      esac
    else
      echo "1) Установить бота"
      echo "0) Назад"
      read -rp "Выбор: " ch
      case "$ch" in
        1) bot_install ;;
        0) return ;;
        *) echo "Неверный выбор" ;;
      esac
    fi
    pause
  done
}

top_menu() {
  while true; do
    echo ""
    echo "======================================"
    echo "  AmneziaWG — единое меню управления"
    echo "======================================"
    echo "1) Клиенты AmneziaWG"
    if awg_is_installed; then
      echo "2) WARP-роутинг"
    fi
    echo "3) Telegram-бот"
    echo "0) Выход"
    read -rp "Выбор: " ch
    case "$ch" in
      1) awg2_main_menu ;;
      2)
        if awg_is_installed; then
          warp_main_menu
        else
          echo "Неверный выбор"
        fi
        ;;
      3) bot_menu ;;
      0) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root (docker/systemctl требуют root). Запусти через sudo." >&2
    exit 1
  fi
  top_menu
fi
