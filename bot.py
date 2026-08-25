#!/usr/bin/env python3
"""
Telegram-бот: управление AmneziaWG (docker, awg2.sh) + WARP-роутинг
для тех же Docker-контейнеров amnezia-awg* (warp.sh).
Доступ только для ADMIN_ID.
"""
import asyncio
import logging
import os
import re
import shlex
from pathlib import Path
import subprocess

from dotenv import load_dotenv
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

load_dotenv()

BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_ID = int(os.environ["ADMIN_ID"])
AWG_SH = os.environ.get("AWG_SH_PATH", "/root/awg2.sh")
WARP_SH = os.environ.get("WARP_SH_PATH", "/root/warp.sh")

logging.basicConfig(
    format="%(asctime)s %(name)s %(levelname)s %(message)s", level=logging.INFO
)
log = logging.getLogger("awg-bot")

# --- conversation states ---
ADD_NAME, SHOW_NAME = range(2)

NAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")


def valid_name(name: str) -> bool:
    return bool(NAME_RE.match(name))


# ---------- shell execution helpers ----------

def _run_sync(sh_path: str, fn_call: str, timeout: int = 60):
    cmd = f'source "{sh_path}" && {fn_call}'
    try:
        p = subprocess.run(
            ["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", f"Таймаут выполнения ({timeout}с)"


async def run_awg(fn_call: str, timeout: int = 60):
    return await asyncio.to_thread(_run_sync, AWG_SH, fn_call, timeout)


async def run_warp(fn_call: str, timeout: int = 60):
    return await asyncio.to_thread(_run_sync, WARP_SH, fn_call, timeout)


def is_admin(update: Update) -> bool:
    return bool(update.effective_chat) and update.effective_chat.id == ADMIN_ID


async def guard(update: Update) -> bool:
    if not is_admin(update):
        if update.effective_message:
            await update.effective_message.reply_text("Доступ запрещён.")
        return False
    return True


def _chunks(text: str, size: int = 3500):
    if not text:
        yield "пусто"
        return
    for i in range(0, len(text), size):
        yield text[i : i + size]


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


async def reply_pre(msg, text: str):
    for chunk in _chunks(text):
        await msg.reply_text(f"<pre>{_esc(chunk)}</pre>", parse_mode=ParseMode.HTML)


# ---------- top-level menu ----------

async def top_menu_kb() -> InlineKeyboardMarkup:
    rows = [[InlineKeyboardButton("🔒 AmneziaWG", callback_data="sec:awg")]]
    # WARP ставится ВНУТРИ контейнера amnezia-awg*, поэтому пункт имеет смысл
    # показывать только когда AmneziaWG уже установлена (иначе ставить некуда).
    rc, _, _ = await run_awg("awg_is_installed", timeout=10)
    if rc == 0:
        rows.append([InlineKeyboardButton("🌊 WARP", callback_data="sec:warp")])
    return InlineKeyboardMarkup(rows)


async def show_top_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = "=== Главное меню ==="
    kb = await top_menu_kb()
    if update.callback_query:
        try:
            await update.callback_query.edit_message_text(text, reply_markup=kb)
        except Exception:
            await update.callback_query.message.reply_text(text, reply_markup=kb)
    else:
        await update.effective_message.reply_text(text, reply_markup=kb)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await guard(update):
        return
    await show_top_menu(update, context)


# ---------- AmneziaWG section ----------

def awg_menu_kb(installed: bool) -> InlineKeyboardMarkup:
    if installed:
        rows = [
            [InlineKeyboardButton("📋 Список клиентов", callback_data="awg:list")],
            [InlineKeyboardButton("➕ Добавить клиента", callback_data="awg:add")],
            [InlineKeyboardButton("🔍 Показать клиента", callback_data="awg:show")],
            [InlineKeyboardButton("➖ Удалить клиента", callback_data="awg:remove")],
            [InlineKeyboardButton("📊 Статистика", callback_data="awg:stats")],
        ]
    else:
        rows = [[InlineKeyboardButton("📦 Установить AmneziaWG", callback_data="awg:install")]]
    rows.append([InlineKeyboardButton("⬅️ Главное меню", callback_data="menu")])
    return InlineKeyboardMarkup(rows)


async def show_awg_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    rc, _, _ = await run_awg("awg_is_installed", timeout=10)
    installed = rc == 0
    text = "=== AmneziaWG ===\n" + (
        "Статус: установлена ✅" if installed else "Статус: НЕ установлена ❌"
    )
    kb = awg_menu_kb(installed)
    if update.callback_query:
        try:
            await update.callback_query.edit_message_text(text, reply_markup=kb)
        except Exception:
            await update.callback_query.message.reply_text(text, reply_markup=kb)
    else:
        await update.effective_message.reply_text(text, reply_markup=kb)


async def _send_awg_client_files(update: Update, context: ContextTypes.DEFAULT_TYPE, name: str) -> bool:
    rc, conf_path, _ = await run_awg(f"awg_client_conf_path {shlex.quote(name)}", timeout=10)
    if rc != 0 or not conf_path:
        return False
    _, png_path, _ = await run_awg(f"awg_client_png_path {shlex.quote(name)}", timeout=10)

    chat_id = update.effective_chat.id
    if Path(conf_path).is_file():
        with open(conf_path, "rb") as f:
            await context.bot.send_document(chat_id, document=f, filename=f"{name}.conf")
    if png_path and Path(png_path).is_file():
        with open(png_path, "rb") as f:
            await context.bot.send_photo(chat_id, photo=f, caption=f"QR: {name}")
    return True


async def add_name_received(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await guard(update):
        return ConversationHandler.END
    name = update.message.text.strip()
    if not valid_name(name):
        await update.message.reply_text("Плохое имя (a-zA-Z0-9_- , до 32 симв.).")
        await show_awg_menu(update, context)
        return ConversationHandler.END
    rc, out, err = await run_awg(f"awg_add_client {shlex.quote(name)}", timeout=30)
    if rc != 0:
        await update.message.reply_text(f"❌ Ошибка:\n{err or out}")
        await show_awg_menu(update, context)
        return ConversationHandler.END

    await update.message.reply_text(f"✅ Клиент '{name}' добавлен.")
    ok = await _send_awg_client_files(update, context, name)
    if not ok:
        await update.message.reply_text("Клиент создан, но файлы конфига найти не удалось — проверь /root/awg вручную.")
    await show_awg_menu(update, context)
    return ConversationHandler.END


async def show_name_received(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await guard(update):
        return ConversationHandler.END
    name = update.message.text.strip()
    if not valid_name(name):
        await update.message.reply_text("Плохое имя (a-zA-Z0-9_- , до 32 симв.).")
        await show_awg_menu(update, context)
        return ConversationHandler.END
    ok = await _send_awg_client_files(update, context, name)
    if not ok:
        await update.message.reply_text(f"Не нашёл клиента '{name}'.")
    await show_awg_menu(update, context)
    return ConversationHandler.END


async def _open_awg_remove_pick(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    rc, out, err = await run_awg("awg_client_lines", timeout=15)
    if rc != 0:
        await q.message.reply_text(f"❌ Ошибка:\n{err or out}")
        await show_awg_menu(update, context)
        return
    items = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name, ip = parts
        items.append((name, ip))
    if not items:
        await q.message.reply_text("Клиентов нет.")
        await show_awg_menu(update, context)
        return
    context.user_data["awg_remove_list"] = items
    rows = [
        [InlineKeyboardButton(f"{name} ({ip})", callback_data=f"awg:rmpick:{i}")]
        for i, (name, ip) in enumerate(items)
    ]
    rows.append([InlineKeyboardButton("⬅️ Отмена", callback_data="sec:awg")])
    await q.edit_message_text("Выбери клиента для удаления:", reply_markup=InlineKeyboardMarkup(rows))


# ---------- WARP section ----------

def warp_menu_kb() -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton("📦 Установить WARP", callback_data="warp:install")],
        [InlineKeyboardButton("🎛 Управление клиентами", callback_data="warp:toggle")],
        [InlineKeyboardButton("📊 Статус", callback_data="warp:status")],
        [InlineKeyboardButton("🔁 Перевыпуск ключа", callback_data="warp:reissue")],
        [InlineKeyboardButton("📋 Список клиентов", callback_data="warp:list")],
        [InlineKeyboardButton("🐳 Проверить контейнеры", callback_data="warp:check")],
        [InlineKeyboardButton("⬅️ Главное меню", callback_data="menu")],
    ]
    return InlineKeyboardMarkup(rows)


async def show_warp_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = "=== WARP-менеджер (Docker) ==="
    kb = warp_menu_kb()
    if update.callback_query:
        try:
            await update.callback_query.edit_message_text(text, reply_markup=kb)
        except Exception:
            await update.callback_query.message.reply_text(text, reply_markup=kb)
    else:
        await update.effective_message.reply_text(text, reply_markup=kb)


async def _get_containers(update: Update):
    rc, out, err = await run_warp("list_containers", timeout=15)
    if rc != 0:
        await update.callback_query.message.reply_text(f"❌ Ошибка:\n{err or out}")
        return []
    return [l.strip() for l in out.splitlines() if l.strip()]


def containers_kb(containers, action: str) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(c, callback_data=f"warp:pick:{action}:{i}")]
        for i, c in enumerate(containers)
    ]
    rows.append([InlineKeyboardButton("⬅️ Отмена", callback_data="sec:warp")])
    return InlineKeyboardMarkup(rows)


async def start_container_pick(update: Update, context: ContextTypes.DEFAULT_TYPE, action: str, prompt: str):
    q = update.callback_query
    containers = await _get_containers(update)
    if not containers:
        await q.message.reply_text("Контейнеры amnezia-awg* не найдены.")
        await show_warp_menu(update, context)
        return
    context.user_data["warp_containers"] = containers
    if len(containers) == 1:
        # единственный контейнер — не спрашиваем, сразу выполняем
        await run_warp_action(update, context, action, containers[0])
        return
    await q.edit_message_text(prompt, reply_markup=containers_kb(containers, action))


async def run_warp_action(update: Update, context: ContextTypes.DEFAULT_TYPE, action: str, container: str):
    q = update.callback_query
    c = shlex.quote(container)

    if action == "install":
        await q.edit_message_text(f"Устанавливаю WARP в {container}, подожди...")
        rc, out, err = await run_warp(f"cmd_install {c}", timeout=300)
        await q.message.reply_text((out or err or "Готово.")[:4000])
        await show_warp_menu(update, context)
        return

    if action == "reissue":
        await q.edit_message_text(f"Перевыпускаю ключ WARP в {container}...")
        rc, out, err = await run_warp(f"cmd_reissue {c}", timeout=120)
        await reply_pre(q.message, out or err or "Готово.")
        await show_warp_menu(update, context)
        return

    if action == "toggle":
        await _open_toggle(update, context, container)
        return


async def button_router(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await guard(update):
        return ConversationHandler.END
    q = update.callback_query
    await q.answer()
    data = q.data

    if data == "menu":
        await show_top_menu(update, context)
        return ConversationHandler.END

    if data == "sec:awg":
        await show_awg_menu(update, context)
        return ConversationHandler.END

    if data == "sec:warp":
        rc, _, _ = await run_awg("awg_is_installed", timeout=10)
        if rc != 0:
            await q.answer("Сначала установи AmneziaWG.", show_alert=True)
            await show_top_menu(update, context)
            return ConversationHandler.END
        await show_warp_menu(update, context)
        return ConversationHandler.END

    # --- AWG ---
    if data == "awg:install":
        await q.edit_message_text("Устанавливаю AmneziaWG, это может занять пару минут...")
        rc, out, err = await run_awg("awg_install", timeout=600)
        msg = "✅ Установлено." if rc == 0 else f"❌ Ошибка установки:\n{err or out}"
        await q.message.reply_text(msg[:4000])
        await show_awg_menu(update, context)
        return ConversationHandler.END

    if data == "awg:list":
        rc, out, err = await run_awg("awg_list_clients_human", timeout=20)
        await reply_pre(q.message, out if rc == 0 and out else (err or "Пусто."))
        await show_awg_menu(update, context)
        return ConversationHandler.END

    if data == "awg:stats":
        rc, out, err = await run_awg("awg_stats", timeout=20)
        await reply_pre(q.message, out if rc == 0 and out else (err or "Нет данных."))
        await show_awg_menu(update, context)
        return ConversationHandler.END

    if data == "awg:add":
        await q.edit_message_text("Введите имя нового клиента (a-zA-Z0-9_- , до 32 симв.):")
        return ADD_NAME

    if data == "awg:show":
        await q.edit_message_text("Введите имя клиента для показа конфига/QR:")
        return SHOW_NAME

    if data == "awg:remove":
        await _open_awg_remove_pick(update, context)
        return ConversationHandler.END

    if data.startswith("awg:rmpick:"):
        idx = int(data.split(":")[2])
        items = context.user_data.get("awg_remove_list") or []
        if not (0 <= idx < len(items)):
            await q.edit_message_text("Список устарел, попробуй снова.")
            await show_awg_menu(update, context)
            return ConversationHandler.END
        name, ip = items[idx]
        context.user_data["awg_remove_name"] = name
        kb = InlineKeyboardMarkup(
            [[InlineKeyboardButton("✅ Да", callback_data="awg:remove_yes"),
              InlineKeyboardButton("❌ Нет", callback_data="awg:remove_no")]]
        )
        await q.edit_message_text(f"Удалить клиента '{name}' ({ip})?", reply_markup=kb)
        return ConversationHandler.END

    if data == "awg:remove_yes":
        name = context.user_data.get("awg_remove_name")
        rc, out, err = await run_awg(f"awg_remove_client {shlex.quote(name)}", timeout=30)
        msg = f"✅ Клиент '{name}' удалён." if rc == 0 else f"❌ Ошибка:\n{err or out}"
        await q.edit_message_text(msg)
        await show_awg_menu(update, context)
        return ConversationHandler.END

    if data == "awg:remove_no":
        await q.edit_message_text("Отменено.")
        await show_awg_menu(update, context)
        return ConversationHandler.END

    # --- WARP ---
    if data == "warp:install":
        await start_container_pick(update, context, "install", "Выбери контейнер для установки WARP:")
        return ConversationHandler.END

    if data == "warp:reissue":
        await start_container_pick(update, context, "reissue", "Выбери контейнер для перевыпуска ключа:")
        return ConversationHandler.END

    if data == "warp:toggle":
        await start_container_pick(update, context, "toggle", "Выбери контейнер:")
        return ConversationHandler.END

    if data == "warp:status":
        rc, out, err = await run_warp("status_menu", timeout=30)
        await reply_pre(q.message, out if rc == 0 and out else (err or "Нет данных."))
        await show_warp_menu(update, context)
        return ConversationHandler.END

    if data == "warp:list":
        rc, out, err = await run_warp("show_clients", timeout=30)
        await reply_pre(q.message, out if rc == 0 and out else (err or "Пусто."))
        await show_warp_menu(update, context)
        return ConversationHandler.END

    if data == "warp:check":
        rc, out, err = await run_warp("check_containers", timeout=15)
        await reply_pre(q.message, out if rc == 0 and out else (err or "Контейнеры не найдены."))
        await show_warp_menu(update, context)
        return ConversationHandler.END

    if data.startswith("warp:pick:"):
        _, _, action, idx_s = data.split(":", 3)
        containers = context.user_data.get("warp_containers") or []
        try:
            container = containers[int(idx_s)]
        except (ValueError, IndexError):
            await q.edit_message_text("Список контейнеров устарел, попробуй снова.")
            await show_warp_menu(update, context)
            return ConversationHandler.END
        await run_warp_action(update, context, action, container)
        return ConversationHandler.END

    # --- WARP toggle (checkbox flow) ---
    if data.startswith("warp:tg:"):
        idx = int(data.split(":")[2])
        st = context.user_data.get("warp_toggle")
        if st and 0 <= idx < len(st["items"]):
            ip, name, state = st["items"][idx]
            st["items"][idx] = (ip, name, 0 if state else 1)
            await _render_toggle(update, context)
        return ConversationHandler.END

    if data == "warp:tgall":
        st = context.user_data.get("warp_toggle")
        if st:
            st["items"] = [(ip, name, 1) for ip, name, _ in st["items"]]
            await _render_toggle(update, context)
        return ConversationHandler.END

    if data == "warp:tgnone":
        st = context.user_data.get("warp_toggle")
        if st:
            st["items"] = [(ip, name, 0) for ip, name, _ in st["items"]]
            await _render_toggle(update, context)
        return ConversationHandler.END

    if data == "warp:tgcancel":
        context.user_data.pop("warp_toggle", None)
        await show_warp_menu(update, context)
        return ConversationHandler.END

    if data == "warp:tgok":
        st = context.user_data.pop("warp_toggle", None)
        if not st:
            await show_warp_menu(update, context)
            return ConversationHandler.END
        enabled_ips = [ip for ip, _, state in st["items"] if state]
        c = shlex.quote(st["container"])
        ips_part = " ".join(shlex.quote(ip) for ip in enabled_ips)
        rc, out, err = await run_warp(f"apply_warp_ips {c} {ips_part}".strip(), timeout=60)
        await q.edit_message_text((out or err or "Применено.")[:4000])
        await show_warp_menu(update, context)
        return ConversationHandler.END

    return ConversationHandler.END


async def _open_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE, container: str):
    rc, out, err = await run_warp(f"warp_client_lines {shlex.quote(container)}", timeout=20)
    if rc != 0:
        await update.callback_query.message.reply_text(f"❌ Ошибка:\n{err or out}")
        await show_warp_menu(update, context)
        return
    items = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        ip, name, state = parts
        items.append((ip, name, int(state)))
    if not items:
        await update.callback_query.message.reply_text("Клиентов нет.")
        await show_warp_menu(update, context)
        return
    context.user_data["warp_toggle"] = {"container": container, "items": items}
    await _render_toggle(update, context)


async def _render_toggle(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st = context.user_data["warp_toggle"]
    rows = []
    for i, (ip, name, state) in enumerate(st["items"]):
        box = "✅" if state else "☐"
        rows.append([InlineKeyboardButton(f"{box} {ip} ({name})", callback_data=f"warp:tg:{i}")])
    on = sum(1 for _, _, s in st["items"] if s)
    rows.append([
        InlineKeyboardButton("Все", callback_data="warp:tgall"),
        InlineKeyboardButton("Никого", callback_data="warp:tgnone"),
    ])
    rows.append([
        InlineKeyboardButton("✅ Применить", callback_data="warp:tgok"),
        InlineKeyboardButton("❌ Отмена", callback_data="warp:tgcancel"),
    ])
    text = f"Контейнер: {st['container']}\nЧерез WARP: {on} из {len(st['items'])}"
    kb = InlineKeyboardMarkup(rows)
    q = update.callback_query
    if q:
        try:
            await q.edit_message_text(text, reply_markup=kb)
        except Exception:
            await q.message.reply_text(text, reply_markup=kb)


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Отменено.")
    await show_top_menu(update, context)
    return ConversationHandler.END


def main():
    if not Path(AWG_SH).is_file():
        raise SystemExit(f"Не найден {AWG_SH} — проверь AWG_SH_PATH в .env")
    if not Path(WARP_SH).is_file():
        raise SystemExit(f"Не найден {WARP_SH} — проверь WARP_SH_PATH в .env")

    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(button_router)],
        states={
            ADD_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, add_name_received)],
            SHOW_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, show_name_received)],
        },
        fallbacks=[CommandHandler("cancel", cancel)],
    )

    app.add_handler(CommandHandler("start", start))
    app.add_handler(conv)

    log.info("Бот запущен.")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
