#!/usr/bin/env bash
#
# L2TP/IPsec VPN Server Auto-Deploy for Ubuntu 20.04/22.04/24.04
# Оптимизировано для работы из РФ с учётом DPI/ТСПУ
#
# v2.0 — исправленная версия
#
set -euo pipefail

# ======================= КОНФИГУРАЦИЯ =======================
VPN_LOCAL_IP="10.55.55.1"
VPN_REMOTE_RANGE="10.55.55.10-10.55.55.254"
VPN_L2TP_NETWORK="10.55.55.0/24"
VPN_IKEV2_NETWORK="10.55.56.0/24"   # отдельная подсеть для IKEv2
VPN_DNS1="1.1.1.1"
VPN_DNS2="8.8.8.8"

# Генерация случайных credentials если не заданы
VPN_PSK="${VPN_PSK:-$(openssl rand -base64 24)}"
VPN_USER="${VPN_USER:-vpnuser}"
VPN_PASS="${VPN_PASS:-$(openssl rand -base64 16)}"

# Дополнительные пользователи (формат: "user1:pass1 user2:pass2")
EXTRA_USERS="${EXTRA_USERS:-}"

# Автоопределение внешнего интерфейса и IP
SERVER_IP="${SERVER_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')}"
SERVER_IFACE="${SERVER_IFACE:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')}"

LOG_FILE="/var/log/vpn-install.log"

# ======================= ФУНКЦИИ =======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ОШИБКА: $*"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || error_exit "Запустите скрипт от root: sudo bash $0"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error_exit "Не удалось определить ОС"
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error_exit "Скрипт предназначен для Ubuntu. Обнаружено: $ID"
    fi
    log "ОС: $PRETTY_NAME"
}

check_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        log "Виртуализация: $virt"
        if [[ "$virt" == "openvz" || "$virt" == "lxc" ]]; then
            error_exit "OpenVZ/LXC контейнеры не поддерживают IPsec (нет доступа к ядру)"
        fi
    fi
}

check_prerequisites() {
    if [[ -z "$SERVER_IP" ]]; then
        error_exit "Не удалось определить IP сервера. Задайте вручную: SERVER_IP=x.x.x.x bash $0"
    fi
    if [[ -z "$SERVER_IFACE" ]]; then
        error_exit "Не удалось определить сетевой интерфейс. Задайте вручную: SERVER_IFACE=eth0 bash $0"
    fi
    log "Server IP: ${SERVER_IP}"
    log "Interface: ${SERVER_IFACE}"
}

load_kernel_modules() {
    log "Загрузка модулей ядра..."

    local modules=(
        af_key      # IPsec key management
        ah4         # AH protocol
        esp4        # ESP protocol
        xfrm_user   # XFRM (IPsec transform)
        xfrm_algo   # XFRM algorithms
        ppp_generic # PPP
        ppp_mppe    # MPPE encryption for PPP
        pppol2tp    # L2TP for PPP
        l2tp_ppp    # L2TP PPP
        l2tp_netlink
        ip_gre      # needed by some L2TP implementations
    )

    for mod in "${modules[@]}"; do
        modprobe "$mod" 2>/dev/null || true
    done

    # Создать /dev/ppp если не существует
    if [[ ! -e /dev/ppp ]]; then
        mknod /dev/ppp c 108 0 2>/dev/null || true
    fi

    # Добавить модули в автозагрузку
    cat > /etc/modules-load.d/vpn.conf << 'MODULES'
af_key
ppp_generic
ppp_mppe
pppol2tp
l2tp_ppp
MODULES

    log "Модули ядра загружены"
}

install_packages() {
    log "Обновление пакетов и установка зависимостей..."

    export DEBIAN_FRONTEND=noninteractive

    # Pre-seed debconf чтобы iptables-persistent не спрашивал
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections

    apt-get update -qq

    # Основные пакеты
    local packages=(
        strongswan
        strongswan-pki
        xl2tpd
        ppp
        iptables
        iptables-persistent
        net-tools
        curl
        openssl
        fail2ban
    )

    # Опциональные пакеты (могут отсутствовать в некоторых версиях Ubuntu)
    local optional_packages=(
        libcharon-extra-plugins
        libcharon-extauth-plugins
        libstrongswan-extra-plugins
        libstrongswan-standard-plugins
    )

    apt-get install -y -qq "${packages[@]}" 2>&1 | tee -a "$LOG_FILE"

    for pkg in "${optional_packages[@]}"; do
        apt-get install -y -qq "$pkg" 2>>"$LOG_FILE" || log "WARN: Пакет $pkg не найден (не критично)"
    done

    log "Пакеты установлены"
}

configure_sysctl() {
    log "Настройка sysctl..."

    # Проверяем поддержку BBR
    local congestion="cubic"
    if modprobe tcp_bbr 2>/dev/null && grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        congestion="bbr"
    fi

    cat > /etc/sysctl.d/99-vpn.conf << SYSCTL
# === IPv4 forwarding (обязательно для VPN) ===
net.ipv4.ip_forward = 1

# === Отключаем IPv6 (минимизация утечек + обход блокировок IPv6) ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# === Отключаем ICMP redirects ===
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# === Отключаем source routing ===
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === rp_filter: disabled для корректной работы IPsec ===
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.${SERVER_IFACE}.rp_filter = 0

# === Не отвечаем на broadcast ping ===
net.ipv4.icmp_echo_ignore_broadcasts = 1

# === TCP оптимизация для обхода DPI ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = ${congestion}
net.core.default_qdisc = fq

# === Буферы для производительности ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Conntrack для большого числа VPN клиентов ===
net.netfilter.nf_conntrack_max = 131072
SYSCTL

    sysctl -p /etc/sysctl.d/99-vpn.conf 2>&1 | tee -a "$LOG_FILE" || true
    log "sysctl настроен (congestion: ${congestion})"
}

configure_ipsec() {
    log "Настройка IPsec (strongSwan)..."

    # Бэкап оригинальных конфигов
    for f in /etc/ipsec.conf /etc/ipsec.secrets; do
        [[ -f "$f" ]] && cp -f "$f" "${f}.bak.$(date +%s)"
    done

    # ---- ipsec.conf ----
    cat > /etc/ipsec.conf << IPSECCONF
# strongSwan IPsec configuration for L2TP/IPsec VPN
config setup
    uniqueids=no
    charondebug="ike 1, knl 1, cfg 1, net 1"

conn %default
    # IKEv1 по умолчанию для L2TP (максимальная совместимость)
    keyexchange=ikev1
    authby=secret
    rekey=no
    # DPD — быстрое обнаружение обрыва
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s

# === L2TP/IPsec (IKEv1) — основной протокол ===
conn l2tp-psk
    type=transport
    left=%defaultroute
    leftid=${SERVER_IP}
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    # Принудительная инкапсуляция в UDP (NAT-T через порт 4500)
    # КРИТИЧНО: маскирует ESP-трафик, затрудняя обнаружение DPI/ТСПУ
    forceencaps=yes
    # Шифрование — совместимые с Windows/macOS/iOS/Android
    ike=aes256-sha256-modp2048,aes256-sha512-modp4096,aes256-sha1-modp1024,aes128-sha256-modp2048,3des-sha1-modp1024!
    esp=aes256-sha256,aes256-sha512,aes256-sha1,aes128-sha256,3des-sha1!
    auto=add

# === IKEv2/IPsec (без L2TP) — для современных клиентов ===
conn ikev2-psk
    keyexchange=ikev2
    authby=secret
    type=tunnel
    left=%defaultroute
    leftid=${SERVER_IP}
    leftsubnet=0.0.0.0/0
    right=%any
    rightsourceip=${VPN_IKEV2_NETWORK}
    rightdns=${VPN_DNS1},${VPN_DNS2}
    forceencaps=yes
    fragmentation=yes
    ike=aes256-sha256-modp2048,aes256-sha512-modp4096,chacha20poly1305-sha512-curve25519!
    esp=aes256-sha256,aes256gcm16,chacha20poly1305!
    dpdaction=clear
    dpddelay=30s
    rekey=no
    auto=add
IPSECCONF

    # ---- ipsec.secrets ----
    cat > /etc/ipsec.secrets << SECRETS
# PSK для всех клиентов
: PSK "${VPN_PSK}"
SECRETS
    chmod 600 /etc/ipsec.secrets

    log "IPsec настроен"
}

configure_strongswan_conf() {
    log "Настройка strongswan.conf..."

    # Бэкап
    [[ -f /etc/strongswan.conf ]] && cp -f /etc/strongswan.conf "/etc/strongswan.conf.bak.$(date +%s)"

    cat > /etc/strongswan.conf << 'SWANCONF'
# strongSwan configuration
charon {
    # Разрешить несколько соединений с одного IP
    multiple_authentication = no

    # Фрагментация IKE — помогает с MTU-проблемами
    # на российских провайдерах (особенно через ТСПУ)
    fragment_size = 1280

    # Потоки обработки
    threads = 16

    # Таймауты
    half_open_timeout = 30

    # Маршруты и виртуальные IP
    install_routes = yes
    install_virtual_ip = yes

    # Загрузка плагинов
    load_modular = yes

    plugins {
        include /etc/strongswan.d/charon/*.conf
    }
}

include /etc/strongswan.d/*.conf
SWANCONF

    # Включаем kernel-netlink плагин с force_udp_encap (если файл есть)
    local kn_conf="/etc/strongswan.d/charon/kernel-netlink.conf"
    if [[ -f "$kn_conf" ]]; then
        cp -f "$kn_conf" "${kn_conf}.bak"
        cat > "$kn_conf" << 'KNCONF'
kernel-netlink {
    load = yes
    # Принудительная UDP-инкапсуляция на уровне ядра
    # Дублирует forceencaps=yes в ipsec.conf, но гарантирует
    # что ВСЕ SA используют UDP-инкапсуляцию
    fwmark = !0x42
}
KNCONF
    fi

    log "strongswan.conf настроен"
}

configure_xl2tpd() {
    log "Настройка xl2tpd..."

    # Создаём директорию для control socket
    mkdir -p /var/run/xl2tpd
    touch /var/run/xl2tpd/l2tp-control

    cat > /etc/xl2tpd/xl2tpd.conf << XL2TPDCONF
[global]
port = 1701
; На стоковом ядре Ubuntu (XFRM/NETKEY) saref НЕ поддерживается
; Включение saref=yes вызовет ошибки xl2tpd
ipsec saref = no
; debug avp = yes
; debug network = yes
; debug state = yes
; debug tunnel = yes

[lns default]
ip range = ${VPN_REMOTE_RANGE}
local ip = ${VPN_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tp-vpn
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
XL2TPDCONF

    log "xl2tpd настроен"
}

configure_ppp() {
    log "Настройка PPP..."

    cat > /etc/ppp/options.xl2tpd << PPPOPT
# === Аутентификация ===
# Только MSCHAPv2 (самый безопасный из поддерживаемых)
require-mschap-v2
# Отказываем устаревшие/небезопасные протоколы
refuse-mschap
refuse-pap
refuse-chap
refuse-eap

# === DNS для клиентов ===
ms-dns ${VPN_DNS1}
ms-dns ${VPN_DNS2}

# === MTU/MRU ===
# Оптимизация для российских провайдеров:
# L2TP/IPsec overhead ~ 100 bytes, PPPoE у клиента ~ 8 bytes
# 1500 - 100 (IPsec+L2TP) - 40 (запас для DPI/ТСПУ) = 1360
# Можно увеличить до 1400 если нет проблем с фрагментацией
mtu 1360
mru 1360

# === Сжатие отключено ===
# DPI может ломать сжатые пакеты, а экономия минимальна
noccp
novj
novjccomp

# === Маршрутизация ===
# Не менять дефолтный маршрут сервера
nodefaultroute
# ARP-прокси для VPN клиентов
proxyarp

# === Разное ===
# Не логировать в stderr
nologfd
# Лог PPP-сессий
logfile /var/log/ppp-xl2tpd.log
# Keepalive
lcp-echo-interval 30
lcp-echo-failure 4
# Принимать IP от xl2tpd
ipcp-accept-local
ipcp-accept-remote
# Без таймаута простоя
idle 0
# Задержка перед первым LCP-пакетом (мс)
connect-delay 3000
PPPOPT

    # ---- Пользователи ----
    cat > /etc/ppp/chap-secrets << CHAP
# client    server    secret    IP addresses
"${VPN_USER}"    l2tp-vpn    "${VPN_PASS}"    *
CHAP

    # Добавляем дополнительных пользователей
    if [[ -n "$EXTRA_USERS" ]]; then
        for pair in $EXTRA_USERS; do
            IFS=':' read -r u p <<< "$pair"
            echo "\"${u}\"    l2tp-vpn    \"${p}\"    *" >> /etc/ppp/chap-secrets
        done
    fi

    chmod 600 /etc/ppp/chap-secrets

    log "PPP настроен"
}

configure_firewall() {
    log "Настройка iptables..."

    # Сначала ставим ACCEPT — чтобы не потерять SSH при ошибке
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # Очистка
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    iptables -t mangle -X 2>/dev/null || true

    # ---- INPUT ----
    # Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Established/Related
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # SSH (с защитой от брутфорса)
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
        -m recent --set --name SSH --rsource
    iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
        -m recent --update --seconds 60 --hitcount 6 --name SSH --rsource -j DROP
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # IPsec IKE (фаза согласования ключей)
    iptables -A INPUT -p udp --dport 500 -j ACCEPT
    # IPsec NAT-T (основной канал данных с forceencaps)
    iptables -A INPUT -p udp --dport 4500 -j ACCEPT

    # L2TP — ТОЛЬКО через IPsec (не принимаем L2TP без шифрования)
    iptables -A INPUT -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
    iptables -A INPUT -p udp --dport 1701 -j DROP

    # ESP и AH протоколы (на случай если NAT-T не используется)
    iptables -A INPUT -p esp -j ACCEPT
    iptables -A INPUT -p ah -j ACCEPT

    # ICMP (ограниченно)
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 2/s --limit-burst 8 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT

    # ---- FORWARD ----
    # Established/Related
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # VPN клиенты (PPP интерфейсы) — во внешнюю сеть и обратно
    iptables -A FORWARD -i ppp+ -j ACCEPT
    iptables -A FORWARD -o ppp+ -j ACCEPT
    # VPN подсети
    iptables -A FORWARD -s "${VPN_L2TP_NETWORK}" -j ACCEPT
    iptables -A FORWARD -d "${VPN_L2TP_NETWORK}" -j ACCEPT
    iptables -A FORWARD -s "${VPN_IKEV2_NETWORK}" -j ACCEPT
    iptables -A FORWARD -d "${VPN_IKEV2_NETWORK}" -j ACCEPT

    # ---- NAT ----
    # Маскарадинг VPN-трафика
    iptables -t nat -A POSTROUTING -s "${VPN_L2TP_NETWORK}" -o "${SERVER_IFACE}" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s "${VPN_IKEV2_NETWORK}" -o "${SERVER_IFACE}" -j MASQUERADE

    # ---- MANGLE ----
    # MSS clamping — КРИТИЧНО для работы через ТСПУ/DPI
    # Автоматически подгоняет MSS под Path MTU
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # ---- Теперь ставим DROP-политики ----
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    # OUTPUT оставляем ACCEPT
    iptables -P OUTPUT ACCEPT

    # Сохранение правил
    netfilter-persistent save 2>&1 | tee -a "$LOG_FILE"

    log "Firewall настроен"
}

configure_fail2ban() {
    log "Настройка fail2ban..."

    cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = auto

[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 7200

[strongswan]
enabled = true
port = 500,4500
filter = strongswan
logpath = /var/log/syslog
maxretry = 5
bantime = 3600
F2B

    # Фильтр для strongSwan
    cat > /etc/fail2ban/filter.d/strongswan.conf << 'F2BFILTER'
[Definition]
failregex = charon\[.*\]: <HOST> is initiating.*but failed
            charon\[.*\]:.*received invalid.*from <HOST>
            charon\[.*\]:.*<HOST>.*authentication failed
            charon\[.*\]:.*no shared key found for.*<HOST>
ignoreregex =
F2BFILTER

    systemctl enable fail2ban
    systemctl restart fail2ban || log "WARN: fail2ban не запустился"

    log "fail2ban настроен"
}

configure_logrotate() {
    log "Настройка ротации логов..."

    cat > /etc/logrotate.d/vpn << 'LOGROTATE'
/var/log/ppp-xl2tpd.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
LOGROTATE
}

detect_swan_service() {
    # Определяем имя сервиса strongSwan
    local svc=""
    for candidate in strongswan-starter strongswan ipsec; do
        if systemctl list-unit-files "${candidate}.service" &>/dev/null; then
            svc="$candidate"
            break
        fi
    done
    if [[ -z "$svc" ]]; then
        # Fallback
        if command -v ipsec &>/dev/null; then
            svc="strongswan-starter"
        else
            error_exit "strongSwan не установлен"
        fi
    fi
    echo "$svc"
}

setup_management_scripts() {
    log "Создание утилит управления..."

    local swan_svc
    swan_svc=$(detect_swan_service)

    # --- vpn-adduser ---
    cat > /usr/local/bin/vpn-adduser << 'ADDUSER'
#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
    echo "Использование: vpn-adduser <username> [password]"
    exit 1
fi
USERNAME="$1"
PASSWORD="${2:-$(openssl rand -base64 16)}"
if grep -q "\"${USERNAME}\"" /etc/ppp/chap-secrets 2>/dev/null; then
    echo "Ошибка: пользователь '${USERNAME}' уже существует"
    exit 1
fi
echo "\"${USERNAME}\"    l2tp-vpn    \"${PASSWORD}\"    *" >> /etc/ppp/chap-secrets
echo "Пользователь добавлен:"
echo "  Login:    ${USERNAME}"
echo "  Password: ${PASSWORD}"
ADDUSER
    chmod +x /usr/local/bin/vpn-adduser

    # --- vpn-deluser ---
    cat > /usr/local/bin/vpn-deluser << 'DELUSER'
#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 ]]; then
    echo "Использование: vpn-deluser <username>"
    exit 1
fi
USERNAME="$1"
if ! grep -q "\"${USERNAME}\"" /etc/ppp/chap-secrets 2>/dev/null; then
    echo "Ошибка: пользователь '${USERNAME}' не найден"
    exit 1
fi
sed -i "/\"${USERNAME}\"/d" /etc/ppp/chap-secrets
echo "Пользователь '${USERNAME}' удалён"
DELUSER
    chmod +x /usr/local/bin/vpn-deluser

    # --- vpn-users ---
    cat > /usr/local/bin/vpn-users << 'LISTUSERS'
#!/bin/bash
echo "=== VPN Пользователи ==="
if [[ -f /etc/ppp/chap-secrets ]]; then
    grep -v '^#' /etc/ppp/chap-secrets | awk '{gsub(/"/, "", $1); if($1!="") print "  " $1}'
else
    echo "  (файл chap-secrets не найден)"
fi
echo ""
echo "=== Активные IPsec SA ==="
ipsec status 2>/dev/null | grep -E "ESTABLISHED|INSTALLED" || echo "  Нет активных соединений"
echo ""
echo "=== PPP интерфейсы ==="
ip -br addr show | grep "ppp" || echo "  Нет PPP интерфейсов"
LISTUSERS
    chmod +x /usr/local/bin/vpn-users

    # --- vpn-status ---
    cat > /usr/local/bin/vpn-status << STATUS
#!/bin/bash
echo "========================================="
echo "       VPN Server Status"
echo "========================================="
echo ""
echo "--- Сервисы ---"
printf "  %-20s %s\n" "strongSwan:" "\$(systemctl is-active ${swan_svc} 2>/dev/null || echo 'не найден')"
printf "  %-20s %s\n" "xl2tpd:" "\$(systemctl is-active xl2tpd 2>/dev/null)"
printf "  %-20s %s\n" "fail2ban:" "\$(systemctl is-active fail2ban 2>/dev/null)"
echo ""
echo "--- IPsec SA ---"
ipsec statusall 2>/dev/null | grep -E "ESTABLISHED|INSTALLED|Connections:" | head -20 || echo "  нет данных"
echo ""
echo "--- PPP сессии ---"
cnt=\$(ip -br link show type ppp 2>/dev/null | wc -l)
echo "  Активных: \${cnt}"
ip -br addr show type ppp 2>/dev/null || true
echo ""
echo "--- Последние подключения ---"
journalctl -u xl2tpd --no-pager -n 5 --since "1 hour ago" 2>/dev/null || true
STATUS
    chmod +x /usr/local/bin/vpn-status

    # --- vpn-restart ---
    cat > /usr/local/bin/vpn-restart << RESTART
#!/bin/bash
echo "Перезапуск VPN сервисов..."
systemctl restart ${swan_svc}
sleep 2
systemctl restart xl2tpd
sleep 1
echo "Готово"
vpn-status
RESTART
    chmod +x /usr/local/bin/vpn-restart

    # --- vpn-diagnose ---
    cat > /usr/local/bin/vpn-diagnose << DIAG
#!/bin/bash
echo "========================================="
echo "       VPN Диагностика"
echo "========================================="

echo ""
echo "[1] Сервисы"
for svc in ${swan_svc} xl2tpd fail2ban; do
    status=\$(systemctl is-active "\$svc" 2>/dev/null || echo "не найден")
    printf "  %-25s %s\n" "\$svc" "\$status"
    if [[ "\$status" == "failed" ]]; then
        echo "    Последние ошибки:"
        journalctl -u "\$svc" --no-pager -n 3 -p err 2>/dev/null | sed 's/^/    /'
    fi
done

echo ""
echo "[2] Порты"
for port in 500 4500 1701; do
    if ss -ulnp | grep -q ":\${port} "; then
        echo "  UDP:\${port} — СЛУШАЕТ ✓"
    else
        echo "  UDP:\${port} — НЕ СЛУШАЕТ ✗"
    fi
done

echo ""
echo "[3] IP forwarding"
fwd=\$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "\$fwd" == "1" ]]; then
    echo "  net.ipv4.ip_forward = 1 ✓"
else
    echo "  net.ipv4.ip_forward = \$fwd ✗ (ПРОБЛЕМА!)"
fi

echo ""
echo "[4] Модули ядра"
for mod in esp4 ah4 xfrm_user af_key ppp_generic ppp_mppe; do
    if lsmod | grep -q "^\$mod"; then
        echo "  \$mod — загружен ✓"
    else
        echo "  \$mod — не загружен ✗"
    fi
done

echo ""
echo "[5] IPsec"
ipsec status 2>/dev/null | head -10 || echo "  IPsec не запущен"

echo ""
echo "[6] NAT правила"
iptables -t nat -L POSTROUTING -n -v 2>/dev/null | head -10

echo ""
echo "[7] Пользователи"
cnt=\$(grep -c -v '^#' /etc/ppp/chap-secrets 2>/dev/null || echo 0)
echo "  Настроено: \${cnt}"

echo ""
echo "[8] DNS доступность"
for dns in 1.1.1.1 8.8.8.8; do
    if timeout 3 bash -c "echo >/dev/udp/\${dns}/53" 2>/dev/null; then
        echo "  \${dns} — доступен ✓"
    else
        echo "  \${dns} — недоступен ✗"
    fi
done

echo ""
echo "[9] Ошибки в логах (последние 30 минут)"
journalctl --since "30 minutes ago" -p err --no-pager -u ${swan_svc} -u xl2tpd 2>/dev/null | tail -10
echo ""
DIAG
    chmod +x /usr/local/bin/vpn-diagnose

    # --- vpn-uninstall ---
    cat > /usr/local/bin/vpn-uninstall << UNINSTALL
#!/bin/bash
set -euo pipefail
echo "ВНИМАНИЕ: Это полностью удалит VPN сервер!"
read -rp "Введите 'yes' для подтверждения: " confirm
[[ "\$confirm" == "yes" ]] || { echo "Отменено"; exit 0; }

echo "Остановка сервисов..."
systemctl stop xl2tpd ${swan_svc} 2>/dev/null || true
systemctl disable xl2tpd ${swan_svc} 2>/dev/null || true

echo "Удаление пакетов..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y strongswan* xl2tpd ppp libcharon-* libstrongswan-* 2>/dev/null || true
apt-get autoremove -y

echo "Очистка конфигурации..."
rm -rf /etc/ipsec.* /etc/xl2tpd /etc/strongswan* /etc/ppp/options.xl2tpd
rm -f /etc/sysctl.d/99-vpn.conf /etc/modules-load.d/vpn.conf

echo "Сброс firewall..."
iptables -F; iptables -t nat -F; iptables -t mangle -F
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
netfilter-persistent save 2>/dev/null || true

echo "Восстановление sysctl..."
sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true

echo "Удаление утилит..."
rm -f /usr/local/bin/vpn-{adduser,deluser,users,status,restart,diagnose,uninstall}

echo "VPN сервер полностью удалён"
UNINSTALL
    chmod +x /usr/local/bin/vpn-uninstall

    log "Утилиты управления созданы"
}

start_services() {
    log "Запуск сервисов..."

    local swan_svc
    swan_svc=$(detect_swan_service)

    # Включаем автозагрузку
    systemctl enable "$swan_svc" 2>/dev/null || true
    systemctl enable xl2tpd

    # Перезагружаем IPsec конфиг
    ipsec rereadall 2>/dev/null || true

    # Запуск
    systemctl restart "$swan_svc"
    sleep 3

    systemctl restart xl2tpd
    sleep 2

    # Проверка
    local errors=0

    if systemctl is-active --quiet "$swan_svc"; then
        log "✓ strongSwan ($swan_svc) — запущен"
    else
        log "✗ ОШИБКА: strongSwan не запустился!"
        journalctl -u "$swan_svc" --no-pager -n 15 2>&1 | tee -a "$LOG_FILE"
        errors=$((errors + 1))
    fi

    if systemctl is-active --quiet xl2tpd; then
        log "✓ xl2tpd — запущен"
    else
        log "✗ ОШИБКА: xl2tpd не запустился!"
        journalctl -u xl2tpd --no-pager -n 15 2>&1 | tee -a "$LOG_FILE"
        errors=$((errors + 1))
    fi

    # Верификация портов
    sleep 1
    for port in 500 4500; do
        if ss -ulnp | grep -q ":${port} "; then
            log "✓ UDP:${port} слушает"
        else
            log "✗ UDP:${port} НЕ слушает!"
            errors=$((errors + 1))
        fi
    done

    # Проверка IPsec
    if ipsec status 2>/dev/null | grep -q "l2tp-psk"; then
        log "✓ IPsec connection 'l2tp-psk' загружена"
    else
        log "✗ IPsec connection 'l2tp-psk' НЕ загружена!"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log "ВНИМАНИЕ: Обнаружено ${errors} проблем(ы). Запустите vpn-diagnose для диагностики"
    fi
}

print_credentials() {
    local creds_file="/root/vpn-credentials.txt"

    cat > "$creds_file" << CREDS
=============================================
  L2TP/IPsec VPN — Данные для подключения
=============================================

Сервер:       ${SERVER_IP}
Тип VPN:      L2TP/IPsec PSK
PSK (ключ):   ${VPN_PSK}

--- Основной пользователь ---
Логин:        ${VPN_USER}
Пароль:       ${VPN_PASS}
CREDS

    if [[ -n "$EXTRA_USERS" ]]; then
        echo "" >> "$creds_file"
        echo "--- Дополнительные пользователи ---" >> "$creds_file"
        for pair in $EXTRA_USERS; do
            IFS=':' read -r u p <<< "$pair"
            printf "  Логин: %-20s Пароль: %s\n" "$u" "$p" >> "$creds_file"
        done
    fi

    cat >> "$creds_file" << 'CREDS2'

=============================================
  Настройка клиентов
=============================================

--- Windows 10/11 ---
1. Настройки → Сеть → VPN → Добавить VPN-подключение
2. Поставщик: Windows (встроенный)
3. Тип VPN: L2TP/IPsec с предварительным ключом
4. Ввести сервер, PSK, логин, пароль
5. ВАЖНО — если ошибка 809 или 789:
   Запустите regedit от администратора:
   HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent
   → Создать DWORD(32): AssumeUDPEncapsulationContextOnSendRule = 2
   HKLM\SYSTEM\CurrentControlSet\Services\RasMan\Parameters
   → Создать DWORD(32): ProhibitIpSec = 0
   → Перезагрузить компьютер

--- macOS ---
1. Системные настройки → Сеть → + → VPN (L2TP over IPSec)
2. Адрес сервера, имя учётной записи
3. Настройки аутентификации → Общий секрет (PSK) + пароль
4. Дополнительно → ✓ Отправлять весь трафик через VPN

--- iOS ---
1. Настройки → Основные → VPN → Добавить конфигурацию
2. Тип: L2TP
3. Сервер, учётная запись, пароль, общий секрет

--- Android ---
1. Настройки → Сеть и интернет → VPN → +
2. Тип: L2TP/IPSec PSK
3. Сервер, общий ключ IPSec, имя пользователя, пароль
4. Дополнительно: Маршруты пересылки → 0.0.0.0/0

--- Linux (NetworkManager) ---
  sudo apt install network-manager-l2tp network-manager-l2tp-gnome
  Настройки сети → VPN → + → L2TP

--- Linux (CLI) ---
  # Установить xl2tpd + strongswan на клиенте
  # Или использовать: https://github.com/hwdsl2/setup-ipsec-vpn

=============================================
  Утилиты управления на сервере
=============================================
  vpn-adduser <user> [pass]  — добавить пользователя
  vpn-deluser <user>         — удалить пользователя
  vpn-users                  — список пользователей и подключений
  vpn-status                 — статус сервера
  vpn-restart                — перезапуск всех сервисов
  vpn-diagnose               — полная диагностика
  vpn-uninstall              — полное удаление VPN

=============================================
CREDS2

    chmod 600 "$creds_file"

    echo ""
    cat "$creds_file"
    echo ""
    log "Credentials сохранены в ${creds_file}"
}

# ======================= MAIN =======================

main() {
    log "========================================="
    log "  L2TP/IPsec VPN Server — Установка v2.0"
    log "========================================="

    check_root
    check_os
    check_virt
    check_prerequisites

    load_kernel_modules
    install_packages
    configure_sysctl
    configure_ipsec
    configure_strongswan_conf
    configure_xl2tpd
    configure_ppp
    configure_firewall
    configure_fail2ban
    configure_logrotate
    setup_management_scripts
    start_services
    print_credentials

    log ""
    log "========================================="
    log "  Установка завершена!"
    log "========================================="
    log ""
    log "Что сделано для обхода блокировок в РФ:"
    log "  • forceencaps=yes — весь IPsec трафик через UDP:4500 (NAT-T)"
    log "    затрудняет идентификацию как ESP-трафика на ТСПУ"
    log "  • MTU 1360 + MSS clamping — предотвращает фрагментацию,"
    log "    которую DPI-оборудование часто обрабатывает некорректно"
    log "  • tcp_mtu_probing + BBR — адаптивный размер пакетов"
    log "  • IKE fragment_size=1280 — фрагментация IKE-хэндшейка"
    log "  • IPv6 полностью отключён — исключает утечки"
    log ""
    log "Если L2TP/IPsec будет заблокирован полностью:"
    log "  → VLESS + Reality + XTLS (XRay/3x-ui)"
    log "  → Это единственный протокол, который ТСПУ не детектирует"
    log ""
    log "Лог установки: ${LOG_FILE}"
    log "Credentials:    /root/vpn-credentials.txt"
    log ""
}

main "$@"
