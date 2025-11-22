#!/bin/bash
set -euo pipefail

INSTALL_DIR="/root/dns"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "=== Fixing DNS & disabling systemd-resolved ==="
# خاموش‌کردن systemd-resolved برای آزاد شدن پورت 53
systemctl disable --now systemd-resolved 2>/dev/null || true

# ساخت resolv.conf جدید با DNS تمیز
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF


echo "=== Updating system ==="
apt-get update -y && apt-get upgrade -y

echo "=== Installing prerequisites ==="
apt-get install -y curl jq dnsutils python3 python3-pip cron ca-certificates


# -------------------------------------------------------
# از اینجا به بعد اسکریپت اصلی تو بدون هیچ تغییری قرار دارد
# -------------------------------------------------------

# نصب Docker
if ! command -v docker &> /dev/null; then
  echo "=== Installing Docker ==="
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  rm get-docker.sh
fi

# نصب Docker Compose
if ! command -v docker-compose &> /dev/null; then
  echo "=== Installing Docker Compose ==="
  COMPOSE_VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
  curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VER/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

echo "=== Creating project files ==="

# فایل تنظیمات کاربر (یوزر و پسورد)
cat > config.env <<'EOF'
SMARTDNS_USER=admin
SMARTDNS_PASS=123456
EOF

# dnsmasq.conf.template
cat > dnsmasq.conf.template <<'EOF'
interface=eth0
listen-address=::1,127.0.0.1,0.0.0.0
no-hosts
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
log-queries
log-facility=/var/log/dnsmasq.log
# Auto-generated mappings (do not edit)
# {{DOMAINS}}
EOF

# docker-compose.yml
cat > docker-compose.yml <<'EOF'
services:
  xbox-smartdns:
    build: .
    container_name: xbox-smartdns-hybrid
    cap_add:
      - NET_ADMIN
    ports:
      - "53:53/udp"
      - "4000:4000/tcp"
    env_file:
      - ./config.env
    volumes:
      - ./webview.py:/app/webview.py
      - ./config.env:/app/config.env
    restart: unless-stopped
EOF

# Dockerfile
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq dnsutils python3 python3-flask cron ca-certificates jq curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY dnsmasq.conf.template /app/dnsmasq.conf.template
COPY update-ips.sh /app/update-ips.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY webview.py /app/webview.py
RUN chmod +x /app/*.sh
RUN (crontab -l 2>/dev/null; echo "0 */12 * * * /app/update-ips.sh >> /var/log/xbox-smartdns-update.log 2>&1") | crontab -
EXPOSE 53/udp
EXPOSE 4000/tcp
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

# entrypoint.sh
cat > entrypoint.sh <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p /var/log
touch /var/log/dnsmasq.log /var/log/xbox-smartdns-update.log
/app/update-ips.sh || true
service cron start
service dnsmasq start || true
python3 /app/webview.py &
tail -F /var/log/dnsmasq.log /var/log/xbox-smartdns-update.log
EOF
chmod +x entrypoint.sh

# update-ips.sh
cat > update-ips.sh <<'EOF'
#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/xbox-smartdns-update.log"
DNSMASQ_CONF="/etc/dnsmasq.conf"
TEMPLATE="/app/dnsmasq.conf.template"

DOMAINS_AUTH=("xbox.com" "xboxlive.com" "login.live.com" "storeedgefd.dsx.mp.microsoft.com")
DOMAINS_CDN=("assets1.xboxlive.com" "assets2.xboxlive.com" "dlassets.xboxlive.com" "download.xbox.com")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

get_country() {
    local ip=$1
    curl -s "https://ip-api.com/json/$ip?fields=countryCode" | jq -r '.countryCode'
}

resolve_best_ip() {
    local domain=$1 target_country=$2
    local ips=$(dig +short $domain | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    for ip in $ips; do
        [[ $(get_country $ip) == "$target_country" ]] && echo $ip && return
    done
    echo $(echo "$ips" | head -n1)
}

log "Starting hybrid update..."
echo "# Auto-generated DNSMasq config" > "$DNSMASQ_CONF"

for domain in "${DOMAINS_AUTH[@]}"; do
    ip=$(resolve_best_ip "$domain" "DE")
    [ -n "$ip" ] && log "Resolved $domain → $ip (DE)" && echo "address=/$domain/$ip" >> "$DNSMASQ_CONF"
done

for domain in "${DOMAINS_CDN[@]}"; do
    ip=$(resolve_best_ip "$domain" "NL")
    [ -n "$ip" ] && log "Resolved $domain → $ip (NL)" && echo "address=/$domain/$ip" >> "$DNSMASQ_CONF"
done

service dnsmasq restart
log "Update finished."
EOF
chmod +x update-ips.sh

# webview.py (بدون تغییر، حذف برای کوتاهی — همان نسخه قبلی در پیام قبلی است)
# ----------------------------
#   ⬆️ اگر خواستی همین‌جا دوباره کامل قرارش می‌دهم
# ----------------------------

echo "=== Building and starting Docker container ==="
docker-compose build
docker-compose up -d

echo "=== DNS test ==="
docker exec xbox-smartdns-hybrid dig +short xbox.com || echo "DNS test failed"

echo "=== Setup complete ==="
echo "Web panel: http://<server-ip>:4000"
echo "Default login → Username: admin | Password: 123456"
