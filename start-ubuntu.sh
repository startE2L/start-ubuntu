
#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# START-UBUNTU v3.2
# Russian / Foreign VPS
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG="/etc/start-ubuntu.conf"
BACKUP="/etc/start-ubuntu-backups"
NFT_CONF="/etc/nftables.conf"
NFT_FILE="/etc/nftables.d/start-rus.nft"
SSHD_CONFIG="/etc/ssh/sshd_config"

OK=0
FAIL=0
KIT_INSTALLED=0

log()  { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[✓]${NC} $*"; }
bad()  { echo -e "${RED}[✗]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

report() {
    local name="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        good "$name"
        ((OK+=1))
    else
        bad "$name"
        ((FAIL+=1))
    fi
}

# ==========================================
# ROOT CHECK
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "Запусти скрипт от root."
    exit 1
fi

mkdir -p "$BACKUP"

# ==========================================
# 1. SERVER TYPE
# ==========================================

echo
echo "=========================================="
echo "          START-UBUNTU v3.2"
echo "=========================================="
echo
echo "Выбери тип сервера:"
echo
echo "r - Российский сервер"
echo "z - Зарубежный сервер"
echo

while true; do
    read -r -p "Выполнить на заграничном или российском сервере? [z/r]: " SERVER_MODE

    SERVER_MODE="${SERVER_MODE,,}"

    if [[ "$SERVER_MODE" == "r" || "$SERVER_MODE" == "z" ]]; then
        break
    fi

    warn "Введи только r или z."
done

if [[ "$SERVER_MODE" == "r" ]]; then
    good "Выбран российский сервер"
else
    good "Выбран зарубежный сервер"
fi

# ==========================================
# 2. ROOT PASSWORD
# ==========================================

echo
log "Установка нового пароля root"

passwd root

# ==========================================
# 3. CURRENT SSH CONNECTION
# ==========================================

CURRENT_CLIENT_IP=""
CURRENT_SSH_PORT=""

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r CURRENT_CLIENT_IP _ _ CURRENT_SSH_PORT <<< "$SSH_CONNECTION"
fi

# ==========================================
# 4. SERVER CONFIGURATION
# ==========================================

echo
log "Введите параметры сервера"

read -r -p "Новый SSH-порт: " SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
    bad "Некорректный SSH-порт"
    exit 1
fi

SSH_PORT=$((10#$SSH_PORT))

if [[ "$SERVER_MODE" == "r" ]]; then

    read -r -p "IPv4 второго сервера: " SERVER_IP
    read -r -p "Порт второго сервера: " SERVER_PORT

    if [[ ! "$SERVER_PORT" =~ ^[0-9]+$ ]] ||
       (( 10#$SERVER_PORT < 1 || 10#$SERVER_PORT > 65535 )); then
        bad "Некорректный порт второго сервера"
        exit 1
    fi

    SERVER_PORT=$((10#$SERVER_PORT))

    if ! python3 -c \
        'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' \
        "$SERVER_IP" 2>/dev/null; then
        bad "Некорректный IPv4 второго сервера"
        exit 1
    fi

fi

# ==========================================
# 5. SAVE CONFIGURATION
# ==========================================

if [[ "$SERVER_MODE" == "r" ]]; then

    cat > "$CONFIG" <<EOF
SERVER_MODE=$SERVER_MODE
SSH_PORT=$SSH_PORT
SERVER_IP=$SERVER_IP
SERVER_PORT=$SERVER_PORT
EOF

else

    cat > "$CONFIG" <<EOF
SERVER_MODE=$SERVER_MODE
SSH_PORT=$SSH_PORT
EOF

fi

chmod 600 "$CONFIG"

good "Параметры сохранены"

echo
echo "Тип сервера: $SERVER_MODE"
echo "SSH PORT: $SSH_PORT"

if [[ "$SERVER_MODE" == "r" ]]; then
    echo "SERVER IP: $SERVER_IP"
    echo "SERVER PORT: $SERVER_PORT"
fi

# ==========================================
# 6. SYSTEM UPDATE
# ==========================================

log "Обновление Ubuntu"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get \
    -o Dpkg::Options::="--force-confold" \
    upgrade -y

apt-get install -y \
    curl \
    vim \
    wget \
    tar \
    python3 \
    ca-certificates

good "Ubuntu обновлена"
good "Базовые пакеты установлены"

# ==========================================
# 7. LIBRESPEED CLI
# ==========================================

log "Установка LibreSpeed CLI"

if [[ "$(uname -m)" != "x86_64" ]]; then
    bad "LibreSpeed: требуется архитектура x86_64"
else

    TMP_DIR=$(mktemp -d)

    if wget -q \
        https://github.com/librespeed/speedtest-cli/releases/latest/download/librespeed-cli_1.0.14_linux_amd64.tar.gz \
        -O "$TMP_DIR/librespeed.tar.gz"; then

        if tar -xzf "$TMP_DIR/librespeed.tar.gz" -C "$TMP_DIR"; then

            if [[ -f "$TMP_DIR/librespeed-cli" ]]; then

                install -m 755 \
                    "$TMP_DIR/librespeed-cli" \
                    /usr/local/bin/librespeed-cli

                good "LibreSpeed CLI установлен"

            else
                bad "Файл librespeed-cli не найден"
            fi

        else
            bad "Ошибка распаковки LibreSpeed"
        fi

    else
        bad "Ошибка загрузки LibreSpeed"
    fi

    rm -rf "$TMP_DIR"

fi

# ==========================================
# 8. SSH CONFIGURATION
# ==========================================

log "Подготовка SSH"

apt-get install -y openssh-server

# Резервная копия основного конфига
if [[ ! -f "$BACKUP/sshd_config" ]]; then
    cp -a "$SSHD_CONFIG" "$BACKUP/sshd_config"
fi

# Резервная копия дополнительных конфигов
if compgen -G "/etc/ssh/sshd_config.d/*.conf" >/dev/null; then

    if [[ ! -d "$BACKUP/sshd_config.d" ]]; then
        mkdir -p "$BACKUP/sshd_config.d"
        cp -a /etc/ssh/sshd_config.d/*.conf "$BACKUP/sshd_config.d/"
    fi

fi

SOCKET_MODE=0

if systemctl is-active --quiet ssh.socket ||
   systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    SOCKET_MODE=1
fi

if (( SOCKET_MODE == 1 )); then

    mkdir -p /etc/systemd/system/ssh.socket.d

    if [[ -d /etc/systemd/system/ssh.socket.d ]] &&
       [[ ! -d "$BACKUP/ssh.socket.d" ]]; then
        cp -a /etc/systemd/system/ssh.socket.d "$BACKUP/ssh.socket.d"
    fi

    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF

    log "Используется systemd ssh.socket"

else

    # Удаляем старые Port из основного конфига
    sed -i -E \
        '/^[[:space:]]*Port[[:space:]]+/Id' \
        "$SSHD_CONFIG"

    # Удаляем Port из дополнительных конфигов
    shopt -s nullglob

    SSH_DROPINS=(/etc/ssh/sshd_config.d/*.conf)

    for file in "${SSH_DROPINS[@]}"; do
        sed -i -E \
            '/^[[:space:]]*Port[[:space:]]+/Id' \
            "$file"
    done

    shopt -u nullglob

    echo "Port $SSH_PORT" >> "$SSHD_CONFIG"

    log "Используется ssh.service"

fi

if ! sshd -t; then
    bad "Ошибка проверки SSH"
    exit 1
fi

good "Новая конфигурация SSH подготовлена"

# ==========================================
# 9. NFTABLES + IP FORWARDING
# ONLY RUSSIAN SERVER
# ==========================================

if [[ "$SERVER_MODE" == "r" ]]; then

    log "Установка nftables"

    if ! command -v nft >/dev/null 2>&1; then
        apt-get install -y nftables
    fi

    mkdir -p /etc/nftables.d

    if [[ -f "$NFT_CONF" ]] &&
       [[ ! -f "$BACKUP/nftables.conf" ]]; then
        cp -a "$NFT_CONF" "$BACKUP/nftables.conf"
    fi

    # IP forwarding
    cat > /etc/sysctl.d/99-ip-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF

    sysctl --system

    # Убираем flush ruleset
    if [[ -f "$NFT_CONF" ]]; then

        sed -i -E \
            '/^[[:space:]]*flush ruleset[[:space:]]*$/Id' \
            "$NFT_CONF"

        sed -i \
            '/# START-RUS BEGIN/,/# START-RUS END/d' \
            "$NFT_CONF"

    else
        touch "$NFT_CONF"
    fi

    # NAT
    cat > "$NFT_FILE" <<EOF
destroy table ip port_forward

table ip port_forward {

    chain prerouting {
        type nat hook prerouting priority dstnat;
        policy accept;

        tcp dport $SERVER_PORT dnat to $SERVER_IP:$SERVER_PORT
        udp dport $SERVER_PORT dnat to $SERVER_IP:$SERVER_PORT
    }

    chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;

        ip daddr $SERVER_IP tcp dport $SERVER_PORT masquerade
        ip daddr $SERVER_IP udp dport $SERVER_PORT masquerade
    }
}
EOF

    cat >> "$NFT_CONF" <<'EOF'

# START-RUS BEGIN
include "/etc/nftables.d/start-rus.nft"
# START-RUS END
EOF

    if nft -c -f "$NFT_CONF"; then

        systemctl enable nftables

        if systemctl restart nftables; then
            good "nftables настроен"
        else
            bad "Не удалось запустить nftables"
        fi

    else
        bad "Ошибка синтаксиса nftables"
    fi

else

    log "Зарубежный сервер: настройка nftables пропущена"
    log "IP forwarding не изменяется"
    good "Межсерверный NAT не настраивается"

fi

# ==========================================
# 10. UFW INSTALLATION
# ==========================================

log "Установка UFW"

if ! command -v ufw >/dev/null 2>&1; then
    apt-get install -y ufw
fi

ufw_rule_exists() {
    ufw show added | grep -Fq -- "$1"
}

allow_tcp() {
    local port="$1"

    if ! ufw_rule_exists "ufw allow $port/tcp"; then
        ufw allow "$port/tcp"
    fi
}

allow_udp() {
    local port="$1"

    if ! ufw_rule_exists "ufw allow $port/udp"; then
        ufw allow "$port/udp"
    fi
}

# ==========================================
# 11. PROTECT CURRENT SSH CONNECTION
# ==========================================

log "Защита текущего SSH-соединения"

if [[ -n "$CURRENT_CLIENT_IP" ]]; then

    ufw allow from "$CURRENT_CLIENT_IP" \
        to any port "$SSH_PORT" proto tcp

    if [[ "$CURRENT_SSH_PORT" =~ ^[0-9]+$ ]]; then

        ufw allow from "$CURRENT_CLIENT_IP" \
            to any port "$CURRENT_SSH_PORT" proto tcp

    fi

    good "Текущий SSH-клиент защищён"

else

    warn "SSH_CONNECTION не определён"
    warn "Будут открыты стандартный и новый SSH-порты"

fi

# ==========================================
# 12. UFW PORT RULES
# ==========================================

log "Настройка портов UFW"

# SSH
allow_tcp 22
allow_tcp "$SSH_PORT"

# HTTP — TCP + UDP
allow_tcp 80
allow_udp 80

# HTTPS — TCP + UDP
allow_tcp 443
allow_udp 443

# ==========================================
# FOREIGN SERVER EXTRA PORTS
# ==========================================

if [[ "$SERVER_MODE" == "z" ]]; then

    log "Открытие дополнительных UDP-портов"

    allow_udp 56000
    allow_udp 56001

    good "56000/udp открыт"
    good "56001/udp открыт"

fi

# ==========================================
# RUSSIAN SERVER EXTRA PORTS
# ==========================================

if [[ "$SERVER_MODE" == "r" ]]; then

    log "Открытие порта второго сервера"

    allow_udp "$SERVER_PORT"

    log "Настройка маршрутизации UFW"

    if ! ufw_rule_exists \
        "ufw route allow proto tcp to $SERVER_IP port $SERVER_PORT"; then

        ufw route allow proto tcp \
            to "$SERVER_IP" port "$SERVER_PORT"

    fi

    if ! ufw_rule_exists \
        "ufw route allow proto udp to $SERVER_IP port $SERVER_PORT"; then

        ufw route allow proto udp \
            to "$SERVER_IP" port "$SERVER_PORT"

    fi

else

    log "Зарубежный сервер: правила ufw route пропущены"

fi

# ==========================================
# 13. ENABLE UFW
# ==========================================

ufw default deny incoming
ufw default allow outgoing

ufw --force enable

if ufw status | grep -q "Status: active"; then
    good "UFW включён"
else
    bad "UFW не активен"
    exit 1
fi

# Сохраняем исходные правила до KIT
ufw show added > "$BACKUP/ufw-before-kit.txt"

# ==========================================
# 14. APPLY SSH PORT
# ==========================================

log "Применение нового SSH-порта"

systemctl daemon-reload

if (( SOCKET_MODE == 1 )); then

    systemctl enable ssh.socket

    if systemctl restart ssh.socket; then
        good "ssh.socket перезапущен"
    else
        bad "Ошибка перезапуска ssh.socket"
    fi

else

    if systemctl restart ssh.service; then
        good "ssh.service перезапущен"
    else
        bad "Ошибка перезапуска ssh.service"
    fi

fi

# ==========================================
# 15. FAIL2BAN
# ==========================================

log "Установка Fail2ban"

apt-get install -y fail2ban python3-systemd

mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/start-ubuntu.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
maxretry = 5
bantime = 1h
findtime = 10m
EOF

if fail2ban-client -t; then

    systemctl enable fail2ban
    systemctl restart fail2ban

    good "Fail2ban настроен"

else
    bad "Ошибка конфигурации Fail2ban"
fi

# ==========================================
# 16. INSTALL 3X-UI KIT
# ==========================================

echo
echo "=========================================="
echo "               3X-UI KIT"
echo "=========================================="

read -r -p "Установить KIT? [y/n]: " INSTALL_KIT

if [[ "$INSTALL_KIT" =~ ^[Yy]$ ]]; then

    log "Загрузка установщика KIT"

    KIT_SCRIPT=$(mktemp)

    if curl -fsSL \
        https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/v1.2.1/scripts/3x-ui.sh \
        -o "$KIT_SCRIPT"; then

        log "Запуск KIT"

        if bash "$KIT_SCRIPT"; then
            good "Установщик KIT завершён"
            KIT_INSTALLED=1
        else
            bad "KIT завершился с ошибкой"
        fi

        rm -f "$KIT_SCRIPT"

    else
        bad "Не удалось загрузить KIT"
        rm -f "$KIT_SCRIPT"
    fi

else

    log "Установка KIT пропущена"

fi

# ==========================================
# 17. CLEAN NEW UFW RULES AFTER KIT
# ==========================================

if (( KIT_INSTALLED == 1 )); then

    echo
    echo "=========================================="
    echo "           KIT UFW CLEANUP"
    echo "=========================================="

    read -r -p "Удалить открытые KIT порты? [y/n]: " CLEAN_KIT

    if [[ "$CLEAN_KIT" =~ ^[Yy]$ ]]; then

        log "Проверка правил UFW после KIT"

        ufw show added > "$BACKUP/ufw-after-kit.txt"

        if python3 - "$BACKUP/ufw-before-kit.txt" \
            "$BACKUP/ufw-after-kit.txt" <<'PY'
import collections
import shlex
import subprocess
import sys


def read_rules(path):
    rules = collections.Counter()

    with open(path, encoding="utf-8") as file:
        for line in file:
            line = line.strip()

            if line.startswith("ufw "):
                rules[line] += 1

    return rules


before = read_rules(sys.argv[1])
after = read_rules(sys.argv[2])

new_rules = after - before

# Удаляем только новые разрешающие правила.
# Остальные правила, включая deny/reject/limit, не трогаем.

rules_to_delete = []

for rule, count in new_rules.items():

    try:
        tokens = shlex.split(rule)
    except ValueError:
        print("Не удалось разобрать правило:", rule)
        continue

    is_allow = (
        len(tokens) >= 3
        and tokens[0] == "ufw"
        and tokens[1] == "allow"
    )

    is_route_allow = (
        len(tokens) >= 4
        and tokens[0] == "ufw"
        and tokens[1] == "route"
        and tokens[2] == "allow"
    )

    if is_allow or is_route_allow:
        rules_to_delete.append((tokens, count))


if not new_rules:
    print("Новых правил UFW нет.")

elif not rules_to_delete:
    print("Новых разрешающих правил UFW для удаления нет.")

errors = 0

for tokens, count in rules_to_delete:

    if tokens[1] == "route":
        command = ["ufw", "--force", "route", "delete"] + tokens[2:]
    else:
        command = ["ufw", "--force", "delete"] + tokens[1:]

    for _ in range(count):

        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        if result.returncode == 0:
            print("Удалено:", shlex.join(tokens))
        else:
            errors += 1
            print("Ошибка удаления:", shlex.join(tokens))
            print(result.stderr.strip())

if errors:
    sys.exit(1)

PY
        then
            good "Очистка новых разрешающих правил KIT завершена"
        else
            bad "При очистке некоторых правил KIT возникли ошибки"
        fi

    else

        log "Правила KIT оставлены без изменений"

    fi

else

    log "KIT не был успешно установлен — очистка не требуется"

fi

# ==========================================
# 18. FINAL REPORT
# ==========================================

echo
echo "=========================================="
echo "           START-UBUNTU REPORT"
echo "=========================================="
echo

report "Конфигурация сохранена" test -s "$CONFIG"

report "LibreSpeed CLI установлен" \
    test -x /usr/local/bin/librespeed-cli

report "SSH конфигурация корректна" sshd -t

if (( SOCKET_MODE == 1 )); then
    report "SSH socket работает" systemctl is-active ssh.socket
else
    report "SSH service работает" systemctl is-active ssh.service
fi

report "UFW активен" \
    bash -c 'ufw status | grep -q "Status: active"'

report "SSH 22/tcp" \
    bash -c 'ufw status | grep -Fq "22/tcp"'

report "Новый SSH-порт" \
    bash -c "ufw status | grep -Fq '${SSH_PORT}/tcp'"

report "HTTP 80/tcp" \
    bash -c 'ufw status | grep -Fq "80/tcp"'

report "HTTP 80/udp" \
    bash -c 'ufw status | grep -Fq "80/udp"'

report "HTTPS 443/tcp" \
    bash -c 'ufw status | grep -Fq "443/tcp"'

report "HTTPS 443/udp" \
    bash -c 'ufw status | grep -Fq "443/udp"'

if [[ "$SERVER_MODE" == "r" ]]; then

    report "IP forwarding включён" \
        test "$(sysctl -n net.ipv4.ip_forward)" = "1"

    report "NAT-таблица существует" \
        nft list table ip port_forward

    report "nftables работает" systemctl is-active nftables

    report "Второй сервер UDP" \
        bash -c "ufw status | grep -Fq '${SERVER_PORT}/udp'"

    report "TCP маршрутизация UFW" \
        bash -c "ufw show added | grep -Fq 'ufw route allow proto tcp to ${SERVER_IP} port ${SERVER_PORT}'"

    report "UDP маршрутизация UFW" \
        bash -c "ufw show added | grep -Fq 'ufw route allow proto udp to ${SERVER_IP} port ${SERVER_PORT}'"

else

    report "56000/udp" \
        bash -c 'ufw status | grep -Fq "56000/udp"'

    report "56001/udp" \
        bash -c 'ufw status | grep -Fq "56001/udp"'

fi

report "Fail2ban работает" systemctl is-active fail2ban

report "Fail2ban SSH jail" \
    fail2ban-client status sshd

# ==========================================
# 19. SUMMARY
# ==========================================

echo
echo "=========================================="
echo "             SERVER SETTINGS"
echo "=========================================="

if [[ "$SERVER_MODE" == "r" ]]; then
    echo "Тип: Российский сервер"
    echo "SSH PORT: $SSH_PORT"
    echo "SERVER IP: $SERVER_IP"
    echo "SERVER PORT: $SERVER_PORT"
else
    echo "Тип: Зарубежный сервер"
    echo "SSH PORT: $SSH_PORT"
    echo "56000/udp: OPEN"
    echo "56001/udp: OPEN"
fi

echo
echo "=========================================="
echo "                RESULT"
echo "=========================================="

echo -e "${GREEN}УСПЕШНО: $OK${NC}"
echo -e "${RED}ОШИБОК: $FAIL${NC}"

echo
echo "Конфигурация: $CONFIG"
echo "Резервные копии: $BACKUP"

if [[ "$SERVER_MODE" == "r" ]]; then
    echo "NAT: $NFT_FILE"
fi

echo

if (( FAIL == 0 )); then
    echo -e "${GREEN}НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
else
    echo -e "${RED}НАСТРОЙКА ЗАВЕРШЕНА С ОШИБКАМИ!${NC}"
fi

echo
echo "=========================================="
echo "Не закрывай текущую SSH-сессию,"
echo "пока не проверишь новое подключение!"
echo "=========================================="
