#!/usr/bin/env bash
# install.sh — установщик единого меню AmneziaWG (docker) + WARP + Telegram-бот.
# Использование на новом сервере:
#   curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh | bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/<USER>/<REPO>/main"
INSTALL_DIR="/opt/amnezia-menu"

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужен root. Запусти через sudo." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

for f in awg2.sh warp.sh menu.sh; do
  echo "Качаю $f..."
  curl -fsSL "$REPO_RAW/$f" -o "$f"
done

# bot.py лежит в подпапке awg-bot/ — там же появятся .env и он сам ждёт его там
# (см. BOT_DIR в menu.sh), рядом с сервис-файлом это не путается с остальными скриптами.
mkdir -p "$INSTALL_DIR/awg-bot"
echo "Качаю bot.py..."
curl -fsSL "$REPO_RAW/bot.py" -o "$INSTALL_DIR/awg-bot/bot.py"

chmod +x awg2.sh warp.sh menu.sh

cat > /usr/local/bin/menu <<WRAP
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/menu.sh"
WRAP
chmod +x /usr/local/bin/menu

echo ""
echo "Готово. Файлы в $INSTALL_DIR, команда: menu"
echo "Дальше: menu -> 1) Клиенты AmneziaWG -> Установить (если контейнера ещё нет)"
echo "        menu -> 3) Telegram-бот -> Установить бота (токен от @BotFather + свой Telegram ID)"
