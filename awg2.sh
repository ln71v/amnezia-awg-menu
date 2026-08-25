#!/usr/bin/env bash
# awg2.sh — управление клиентами AmneziaWG внутри Docker-контейнера amnezia-awg*
# (того же формата, что ставит официальное приложение Amnezia).
# Требует уже существующий контейнер amnezia-awg* (см. warp.sh для WARP-роутинга —
# он работает с этим же контейнером без изменений).
set -uo pipefail

AWG_CONF_IN="/opt/amnezia/awg/awg0.conf"
CLIENTS_TABLE_IN="/opt/amnezia/awg/clientsTable"
CLIENTS_DIR="/root/awg2-clients"
LOCK_FILE="/var/lock/awg2-manage.lock"
NAME_RE='^[a-zA-Z0-9_-]{1,32}$'

mkdir -p "$CLIENTS_DIR"

_awg2_container() {
  docker ps --format '{{.Names}}' | grep -E '^amnezia-awg' | head -n1
}

awg_is_installed() {
  local c
  c=$(_awg2_container)
  [ -n "$c" ] && docker exec "$c" test -f "$AWG_CONF_IN" 2>/dev/null
}

_awg2_valid_name() { [[ "$1" =~ $NAME_RE ]]; }

# Читает [Interface]-секцию сервера (до первого [Peer]) в переменные SRV_*
_awg2_load_server_iface() {
  local c="$1"
  local raw
  raw=$(docker exec "$c" awk '/^\[Peer\]/{exit} {print}' "$AWG_CONF_IN")
  SRV_PORT=$(echo "$raw" | awk -F' = ' '/^ListenPort/{print $2}')
  SRV_ADDR=$(echo "$raw" | awk -F' = ' '/^Address/{print $2}')
  SRV_JC=$(echo "$raw" | awk -F' = ' '/^Jc /{print $2}')
  SRV_JMIN=$(echo "$raw" | awk -F' = ' '/^Jmin /{print $2}')
  SRV_JMAX=$(echo "$raw" | awk -F' = ' '/^Jmax /{print $2}')
  SRV_S1=$(echo "$raw" | awk -F' = ' '/^S1 /{print $2}')
  SRV_S2=$(echo "$raw" | awk -F' = ' '/^S2 /{print $2}')
  SRV_S3=$(echo "$raw" | awk -F' = ' '/^S3 /{print $2}')
  SRV_S4=$(echo "$raw" | awk -F' = ' '/^S4 /{print $2}')
  SRV_H1=$(echo "$raw" | awk -F' = ' '/^H1 /{print $2}')
  SRV_H2=$(echo "$raw" | awk -F' = ' '/^H2 /{print $2}')
  SRV_H3=$(echo "$raw" | awk -F' = ' '/^H3 /{print $2}')
  SRV_H4=$(echo "$raw" | awk -F' = ' '/^H4 /{print $2}')
  SRV_PUBKEY=$(docker exec "$c" cat /opt/amnezia/awg/wireguard_server_public_key.key)
}

_awg2_next_ip() {
  local c="$1"
  local subnet used next
  subnet=$(echo "$SRV_ADDR" | cut -d/ -f1 | cut -d. -f1-3)
  used=$(docker exec "$c" awk -F' = ' '/^AllowedIPs/{print $2}' "$AWG_CONF_IN" | cut -d/ -f1 | cut -d. -f4)
  next=""
  for i in $(seq 1 254); do
    if ! echo "$used" | grep -qx "$i"; then next="$i"; break; fi
  done
  [ -n "$next" ] && echo "${subnet}.${next}"
}

_awg2_server_ip() {
  curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null
}

awg_add_client() {
  local name="$1"
  local c
  c=$(_awg2_container)
  [ -z "$c" ] && { echo "Контейнер amnezia-awg* не найден. Сначала установи." >&2; return 1; }
  _awg2_valid_name "$name" || { echo "Плохое имя клиента: '$name' (a-zA-Z0-9_- , до 32 симв.)" >&2; return 1; }

  (
    flock -w 15 9 || { echo "Не удалось взять лок." >&2; exit 1; }

    _awg2_load_server_iface "$c"

    local priv pub psk ip
    priv=$(docker exec "$c" awg genkey)
    pub=$(echo "$priv" | docker exec -i "$c" awg pubkey)
    psk=$(docker exec "$c" awg genpsk)
    ip=$(_awg2_next_ip "$c")
    if [ -z "$ip" ]; then
      echo "Нет свободных IP в подсети $SRV_ADDR." >&2
      exit 1
    fi

    local conf_local
    conf_local=$(mktemp)
    docker exec "$c" cat "$AWG_CONF_IN" > "$conf_local"
    python3 - "$conf_local" "$pub" "$psk" "$ip" <<'PY'
import sys
path, pub, psk, ip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
if not content.endswith("\n"):
    content += "\n"
content += f"[Peer]\nPublicKey = {pub}\nPresharedKey = {psk}\nAllowedIPs = {ip}/32\n"
with open(path, "w") as f:
    f.write(content)
PY
    docker exec -i "$c" sh -c "cat > $AWG_CONF_IN" < "$conf_local"
    rm -f "$conf_local"

    local table_local table_new
    table_local=$(mktemp)
    table_new=$(mktemp)
    docker exec "$c" cat "$CLIENTS_TABLE_IN" > "$table_local" 2>/dev/null || echo '[]' > "$table_local"
    python3 - "$table_local" "$pub" "$name" > "$table_new" <<'PY'
import json, sys, datetime
path, pubkey, name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = []
data.append({
    "clientId": pubkey,
    "userData": {
        "clientName": name,
        "creationDate": datetime.datetime.now().strftime("%a %b %d %H:%M:%S %Y"),
    },
})
json.dump(data, sys.stdout, indent=4)
PY
    docker exec -i "$c" sh -c "cat > $CLIENTS_TABLE_IN" < "$table_new"
    rm -f "$table_local" "$table_new"

    # hot-reload интерфейса без разрыва остальных клиентов
    docker exec "$c" bash -c "awg syncconf awg0 <(awg-quick strip $AWG_CONF_IN)"

    local srv_ip conf
    srv_ip=$(_awg2_server_ip)
    conf="$CLIENTS_DIR/$name.conf"
    cat > "$conf" <<CONF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = 1.1.1.1
MTU = 1280
Jc = $SRV_JC
Jmin = $SRV_JMIN
Jmax = $SRV_JMAX
S1 = $SRV_S1
S2 = $SRV_S2
S3 = $SRV_S3
S4 = $SRV_S4
H1 = $SRV_H1
H2 = $SRV_H2
H3 = $SRV_H3
H4 = $SRV_H4

[Peer]
PublicKey = $SRV_PUBKEY
PresharedKey = $psk
Endpoint = ${srv_ip}:${SRV_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t png -o "$CLIENTS_DIR/$name.png" < "$conf"
    fi
    echo "Клиент '$name' добавлен, IP $ip."
  ) 9>"$LOCK_FILE"
}

awg_remove_client() {
  local name="$1"
  local c
  c=$(_awg2_container)
  [ -z "$c" ] && { echo "Контейнер не найден." >&2; return 1; }
  _awg2_valid_name "$name" || { echo "Плохое имя: '$name'" >&2; return 1; }

  (
    flock -w 15 9 || { echo "Не удалось взять лок." >&2; exit 1; }

    local table_local pub
    table_local=$(mktemp)
    docker exec "$c" cat "$CLIENTS_TABLE_IN" > "$table_local" 2>/dev/null || echo '[]' > "$table_local"
    pub=$(python3 - "$table_local" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for e in data:
    if e.get("userData", {}).get("clientName") == name:
        print(e["clientId"])
        break
PY
)
    if [ -z "$pub" ]; then
      echo "Клиент '$name' не найден." >&2
      rm -f "$table_local"
      exit 1
    fi

    local conf_local
    conf_local=$(mktemp)
    docker exec "$c" cat "$AWG_CONF_IN" > "$conf_local"
    python3 - "$conf_local" "$pub" <<'PY'
import sys
path, pub = sys.argv[1], sys.argv[2]
content = open(path).read()
parts = content.split("[Peer]")
header = parts[0]
kept = [p for p in parts[1:] if f"PublicKey = {pub}" not in p]
new_content = header + "".join("[Peer]" + p for p in kept)
new_content = new_content.rstrip("\n") + "\n"
open(path, "w").write(new_content)
PY
    docker exec -i "$c" sh -c "cat > $AWG_CONF_IN" < "$conf_local"

    local table_new
    table_new=$(mktemp)
    python3 - "$table_local" "$pub" > "$table_new" <<'PY'
import json, sys
path, pub = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data = [e for e in data if e.get("clientId") != pub]
json.dump(data, sys.stdout, indent=4)
PY
    docker exec -i "$c" sh -c "cat > $CLIENTS_TABLE_IN" < "$table_new"
    rm -f "$table_local" "$table_new" "$conf_local"

    docker exec "$c" bash -c "awg syncconf awg0 <(awg-quick strip $AWG_CONF_IN)"
    rm -f "$CLIENTS_DIR/$name.conf" "$CLIENTS_DIR/$name.png"
    echo "Клиент '$name' удалён."
  ) 9>"$LOCK_FILE"
}

awg_list_clients_human() {
  local c
  c=$(_awg2_container)
  [ -z "$c" ] && { echo "Контейнер не найден."; return 1; }
  local table_local peers_local
  table_local=$(mktemp)
  peers_local=$(mktemp)
  docker exec "$c" cat "$CLIENTS_TABLE_IN" > "$table_local" 2>/dev/null || echo '[]' > "$table_local"
  docker exec "$c" awk '
    /^\[Peer\]/{pk="";ip=""}
    /^PublicKey/{split($0,a,"= ");pk=a[2]}
    /^AllowedIPs/{split($0,a,"= ");ip=a[2]; if(pk!="") print pk"\t"ip}
  ' "$AWG_CONF_IN" > "$peers_local"
  python3 - "$peers_local" "$table_local" <<'PY'
import sys, json
peers_path, table_path = sys.argv[1], sys.argv[2]
try:
    table = {e["clientId"]: e["userData"]["clientName"] for e in json.load(open(table_path))}
except Exception:
    table = {}
print(f"{'Имя':20} {'IP':16} PublicKey")
print("-" * 70)
with open(peers_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        pk, ip = line.split("\t")
        name = table.get(pk, "(без имени)")
        print(f"{name:20} {ip:16} {pk[:16]}...")
PY
  rm -f "$table_local" "$peers_local"
}

awg_client_conf_path() {
  local name="$1"
  _awg2_valid_name "$name" || return 1
  local f="$CLIENTS_DIR/$name.conf"
  [ -f "$f" ] && echo "$f"
}

awg_client_png_path() {
  local name="$1"
  _awg2_valid_name "$name" || return 1
  local f="$CLIENTS_DIR/$name.png"
  [ -f "$f" ] && echo "$f"
}

awg_show_client() {
  local name="$1"
  local conf
  conf=$(awg_client_conf_path "$name")
  [ -z "$conf" ] && { echo "Не нашёл конфиг для '$name'." >&2; return 1; }
  if command -v qrencode >/dev/null 2>&1; then
    echo "--- QR ---"
    qrencode -t ansiutf8 < "$conf"
  fi
  echo "--- Путь: $conf ---"
  cat "$conf"
}

awg_stats() {
  local c
  c=$(_awg2_container)
  [ -z "$c" ] && { echo "Контейнер не найден."; return 1; }
  docker exec "$c" awg show awg0
}

# Машиночитаемый список клиентов: "имя\tip" по одному в строке.
# Используется и терминальным пикером (_awg2_pick_client), и ботом (кнопки).
awg_client_lines() {
  local c
  c=$(_awg2_container)
  [ -z "$c" ] && { echo "Контейнер не найден." >&2; return 1; }
  local table_local peers_local
  table_local=$(mktemp)
  peers_local=$(mktemp)
  docker exec "$c" cat "$CLIENTS_TABLE_IN" > "$table_local" 2>/dev/null || echo '[]' > "$table_local"
  docker exec "$c" awk '
    /^\[Peer\]/{pk="";ip=""}
    /^PublicKey/{split($0,a,"= ");pk=a[2]}
    /^AllowedIPs/{split($0,a,"= ");ip=a[2]; if(pk!="") print pk"\t"ip}
  ' "$AWG_CONF_IN" > "$peers_local"
  python3 - "$peers_local" "$table_local" <<'PY'
import sys, json
peers_path, table_path = sys.argv[1], sys.argv[2]
try:
    table = {e["clientId"]: e["userData"]["clientName"] for e in json.load(open(table_path))}
except Exception:
    table = {}
with open(peers_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        pk, ip = line.split("\t")
        name = table.get(pk, "(без имени)")
        print(f"{name}\t{ip}")
PY
  rm -f "$table_local" "$peers_local"
}

# Печатает пронумерованный список клиентов (в stderr, чтобы не мешать выводу
# функции в $(...)) и возвращает выбранное ИМЯ через stdout.
_awg2_pick_client() {
  local list_local
  list_local=$(mktemp)
  awg_client_lines > "$list_local" || { rm -f "$list_local"; return 1; }

  local names=() nm ip i=1
  while IFS=$'\t' read -r nm ip; do
    [ -z "$nm" ] && continue
    names+=("$nm")
    echo "  $i) $nm ($ip)" >&2
    i=$((i+1))
  done < "$list_local"
  rm -f "$list_local"

  if [ ${#names[@]} -eq 0 ]; then
    echo "Клиентов нет." >&2
    return 1
  fi

  echo -n "Номер клиента: " >&2
  local sel
  read -r sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then
    echo "Нет такого номера." >&2
    return 1
  fi
  echo "${names[$((sel-1))]}"
}

_awg2_free_port() {
  local p
  for _ in $(seq 1 30); do
    p=$(( (RANDOM % 50000) + 10000 ))
    if ! ss -uln 2>/dev/null | grep -q ":${p} "; then echo "$p"; return; fi
  done
  echo "51820"
}

# Устанавливает AmneziaWG с нуля — создаёт docker-контейнер того же формата,
# что и официальное приложение Amnezia (без него, самостоятельно).
awg_install() {
  local c
  c=$(_awg2_container)
  if [ -n "$c" ]; then
    echo "Контейнер $c уже существует и используется — новый не создаю."
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker не найден, ставлю..."
    curl -fsSL https://get.docker.com | sh
  fi

  local n=1
  while docker ps -a --format '{{.Names}}' | grep -qx "amnezia-awg${n}"; do n=$((n+1)); done
  local name="amnezia-awg${n}"
  local port subnet
  port=$(_awg2_free_port)
  subnet="10.8.${n}.0/24"

  echo "Тяну образ amneziavpn/amneziawg-go..."
  docker pull amneziavpn/amneziawg-go:latest >/dev/null

  echo "Генерирую ключи сервера..."
  local priv pub
  priv=$(docker run --rm --entrypoint awg amneziavpn/amneziawg-go:latest genkey)
  pub=$(echo "$priv" | docker run --rm -i --entrypoint awg amneziavpn/amneziawg-go:latest pubkey)

  echo "Генерирую параметры обфускации..."
  local params
  params=$(python3 <<'PY'
import random
jc = random.randint(3, 6)
jmin = random.randint(40, 89)
jmax = jmin + random.randint(50, 250)
def pick_s():
    return random.randint(15, 150)
s1 = pick_s()
s2 = pick_s()
while s1 + 56 == s2:
    s2 = pick_s()
s3 = random.randint(8, 55)
s4 = random.randint(4, 27)
hs = set()
while len(hs) < 4:
    hs.add(random.randint(5, 2**32 - 1000))
h1, h2, h3, h4 = list(hs)
print(jc, jmin, jmax, s1, s2, s3, s4, h1, h2, h3, h4)
PY
)
  read -r p_jc p_jmin p_jmax p_s1 p_s2 p_s3 p_s4 p_h1 p_h2 p_h3 p_h4 <<< "$params"

  local workdir
  workdir=$(mktemp -d)
  mkdir -p "$workdir/awg"

  cat > "$workdir/awg/awg0.conf" <<CONF
[Interface]
PrivateKey = $priv
Address = $subnet
ListenPort = $port
Jc = $p_jc
Jmin = $p_jmin
Jmax = $p_jmax
S1 = $p_s1
S2 = $p_s2
S3 = $p_s3
S4 = $p_s4
H1 = $p_h1
H2 = $p_h2
H3 = $p_h3
H4 = $p_h4
CONF
  echo '[]' > "$workdir/awg/clientsTable"
  echo "$pub" > "$workdir/awg/wireguard_server_public_key.key"
  : > "$workdir/client_names.txt"

  cat > "$workdir/start.sh" <<STARTSH
#!/bin/bash
echo "Container startup"
awg-quick down /opt/amnezia/awg/awg0.conf
if [ -f /opt/amnezia/awg/awg0.conf ]; then (awg-quick up /opt/amnezia/awg/awg0.conf); fi
iptables -A INPUT -i awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -j ACCEPT
iptables -A OUTPUT -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o eth0 -s $subnet -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s $subnet -o eth0 -j MASQUERADE
# --- WARP-MANAGER BEGIN ---
# --- WARP-MANAGER END ---
tail -f /dev/null
STARTSH

  echo "Создаю контейнер $name (порт $port/udp, подсеть $subnet)..."
  docker create --name "$name" \
    --restart always \
    --privileged \
    --cap-add NET_ADMIN --cap-add SYS_MODULE \
    --security-opt label=disable \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    -v /lib/modules:/lib/modules \
    -p "${port}:${port}/udp" \
    --entrypoint bash \
    amneziavpn/amneziawg-go:latest /opt/amnezia/start.sh >/dev/null

  docker cp "$workdir/." "$name:/opt/amnezia"
  rm -rf "$workdir"

  docker start "$name" >/dev/null
  sleep 2

  if docker exec "$name" test -f "$AWG_CONF_IN" 2>/dev/null; then
    echo "Готово: контейнер $name поднят, порт $port/udp, подсеть $subnet."
  else
    echo "Что-то пошло не так, проверь: docker logs $name" >&2
    return 1
  fi
}

pause() { read -rp "Enter — продолжить..." _; }

awg2_main_menu() {
  while true; do
    echo ""
    echo "=== AmneziaWG (docker): меню ==="
    if awg_is_installed; then
      echo "Статус: установлена"
      echo "1) Список клиентов"
      echo "2) Добавить клиента"
      echo "3) Удалить клиента"
      echo "4) Статистика"
      echo "0) Назад"
      read -rp "Выбор: " ch
      case "$ch" in
        1) awg_list_clients_human ;;
        2) read -rp "Имя клиента: " n; awg_add_client "$n" && awg_show_client "$n" ;;
        3) n=$(_awg2_pick_client) && awg_remove_client "$n" ;;
        4) awg_stats ;;
        0) return ;;
        *) echo "Неверный выбор" ;;
      esac
    else
      echo "Статус: НЕ установлена (контейнер amnezia-awg* не найден)"
      echo "1) Установить"
      echo "0) Назад"
      read -rp "Выбор: " ch
      case "$ch" in
        1) awg_install ;;
        0) return ;;
        *) echo "Неверный выбор" ;;
      esac
    fi
    pause
  done
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Нужен root (docker требует root). Запусти через sudo." >&2
    exit 1
  fi
  awg2_main_menu
fi
