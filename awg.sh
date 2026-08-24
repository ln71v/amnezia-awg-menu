#!/usr/bin/env bash
# awg.sh — установка/список/добавление/удаление клиентов AmneziaWG + меню.
# Bare-metal через bivlked/amneziawg-installer.
#
# Запуск как меню:      ./awg.sh
# Подключение как либа (бот и т.п.): source ./awg.sh   — меню при этом не стартует.

set -uo pipefail

AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/awg0.conf"
MANAGE_SH="/root/awg/manage_amneziawg.sh"
INSTALL_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.15.6/install_amneziawg.sh"
LOCK_FILE="/var/lock/awg-manage.lock"
NAME_RE='^[a-zA-Z0-9_-]{1,32}$'

awg_is_installed() {
  [ -f "$AWG_CONF" ] && systemctl is-active --quiet awg-quick@awg0
}

awg_install() {
  if awg_is_installed; then
    echo "Уже установлено." >&2
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  if ! wget -q -O "$tmp" "$INSTALL_URL"; then
    echo "Не удалось скачать установщик ($INSTALL_URL)." >&2
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  bash "$tmp"
  local rc=$?
  rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    echo "Установка упала с кодом $rc." >&2
    return "$rc"
  fi
  if ! awg_is_installed; then
    echo "Установщик отработал, но awg-quick@awg0 не активен — проверь руками." >&2
    return 1
  fi
}

# Официальный синтаксис по README — "sudo bash /root/awg/manage_amneziawg.sh ...",
# т.е. файл не обязан быть +x. Проверяем -f, вызываем через bash, а не напрямую.
awg_require_manage() {
  if [ ! -f "$MANAGE_SH" ]; then
    echo "Не найден $MANAGE_SH — Amnezia не установлена или путь другой." >&2
    return 1
  fi
}

awg_manage() {
  bash "$MANAGE_SH" "$@"
}

_awg_valid_name() {
  [[ "$1" =~ $NAME_RE ]]
}

awg_list_clients_json() {
  awg_require_manage || return 1
  awg_manage list -v --json
}

# ВНИМАНИЕ: точные имена полей в --json не подтверждены (в README мелькает только
# "client_ipv6", не "name"/"status"/"expires") — гадать их для парсинга опасно,
# поэтому по умолчанию берём обычный человекочитаемый вывод -v. Когда узнаешь
# реальную схему JSON (глянь `awg_list_clients_json` руками) — поправь тут на jq.
awg_list_clients_human() {
  awg_require_manage || return 1
  awg_manage list -v
}

awg_add_client() {
  local name="$1" expires="${2:-}"
  awg_require_manage || return 1
  if ! _awg_valid_name "$name"; then
    echo "Плохое имя клиента: '$name' (разрешено a-zA-Z0-9_- , до 32 симв.)" >&2
    return 1
  fi
  (
    flock -w 10 9 || { echo "Не удалось взять лок." >&2; exit 1; }
    if [ -n "$expires" ]; then
      awg_manage add "$name" --expires="$expires"
    else
      awg_manage add "$name"
    fi
  ) 9>"$LOCK_FILE"
}

awg_remove_client() {
  local name="$1"
  awg_require_manage || return 1
  if ! _awg_valid_name "$name"; then
    echo "Плохое имя клиента: '$name'" >&2
    return 1
  fi
  (
    flock -w 10 9 || { echo "Не удалось взять лок." >&2; exit 1; }
    awg_manage remove "$name"
  ) 9>"$LOCK_FILE"
}

# По README файлы клиента лежат прямо в /root/awg/<имя>.conf и /root/awg/<имя>.png
# (плюс <имя>.vpnuri). find оставлен как подстраховка на случай подпапок/суффиксов.
awg_client_conf_path() {
  local name="$1"
  _awg_valid_name "$name" || return 1
  local f="/root/awg/$name.conf"
  [ -f "$f" ] && { echo "$f"; return 0; }
  find "$AWG_DIR" /root/awg -maxdepth 3 -iname "${name}.conf" 2>/dev/null | head -n1
}

awg_client_png_path() {
  local name="$1"
  _awg_valid_name "$name" || return 1
  local f="/root/awg/$name.png"
  [ -f "$f" ] && { echo "$f"; return 0; }
  find "$AWG_DIR" /root/awg -maxdepth 3 -iname "${name}.png" 2>/dev/null | head -n1
}

# Печатает QR в терминал (ansi) + путь к конфигу + сам конфиг текстом,
# чтобы можно было забрать файл через Termius (SFTP по пути) или скопировать текст руками.
awg_show_client() {
  local name="$1"
  local conf png
  conf=$(awg_client_conf_path "$name")
  png=$(awg_client_png_path "$name")

  if [ -z "$conf" ]; then
    echo "Не нашёл .conf для '$name' — пути-кандидаты не подошли, ищи руками в /root/awg." >&2
    return 1
  fi

  if command -v qrencode >/dev/null 2>&1; then
    echo "--- QR ---"
    qrencode -t ansiutf8 < "$conf"
  else
    echo "qrencode не установлен (apt install qrencode) — QR в терминале не показать." >&2
  fi

  echo "--- Файл конфига (забрать через Termius SFTP по пути ниже, или скопировать текст) ---"
  echo "Путь: $conf"
  [ -n "$png" ] && echo "QR-файл: $png"
  echo "--- Содержимое ---"
  cat "$conf"
  echo "--- конец ---"
}

awg_stats() {
  awg_require_manage || return 1
  awg_manage stats --json
}

pause() { read -rp "Enter — продолжить..." _; }

main_menu() {
  while true; do
    echo ""
    echo "=== AmneziaWG: меню ==="
    if awg_is_installed; then
      echo "Статус: установлена, awg-quick@awg0 активен"
      echo "1) Список клиентов"
      echo "2) Добавить клиента"
      echo "3) Удалить клиента"
      echo "4) Статистика"
      echo "0) Выход"
      read -rp "Выбор: " ch
      case "$ch" in
        1) awg_list_clients_human ;;
        2)
          read -rp "Имя клиента: " n
          if awg_add_client "$n"; then
            awg_show_client "$n"
          fi
          ;;
        3) read -rp "Имя клиента: " n; awg_remove_client "$n" ;;
        4) awg_stats ;;
        0) exit 0 ;;
        *) echo "Неверный выбор" ;;
      esac
    else
      echo "Статус: НЕ установлена"
      echo "1) Установить Amnezia"
      echo "0) Выход"
      read -rp "Выбор: " ch
      case "$ch" in
        1) awg_install ;;
        0) exit 0 ;;
        *) echo "Неверный выбор" ;;
      esac
    fi
    pause
  done
}

# Меню стартует только при прямом запуске (./awg.sh), не при `source ./awg.sh`.
# ':-' на случай, если код вставили прямо в интерактивный шелл, а не запустили как файл —
# там BASH_SOURCE пуст, и без дефолта это падает с "unbound variable" из-за set -u выше.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root (systemctl/awg-quick/установка требуют root). Запусти через sudo." >&2
    exit 1
  fi
  main_menu
fi
