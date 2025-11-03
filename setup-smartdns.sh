#!/bin/bash
set -e

BASE_DIR="/root/dns"
ZIP_FILE="/root/xbox-smartdns-hybrid-final.zip"
CONTAINER_NAME="xbox-smartdns-hybrid"

echo ""
echo "🚀 Xbox SmartDNS Hybrid - Auto Builder & Runner"
echo "-----------------------------------------------"

# 🧹 پاکسازی نسخه‌های قبلی
echo "[1/7] Cleaning old setup..."
docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
docker rm $CONTAINER_NAME >/dev/null 2>&1 || true
rm -rf "$BASE_DIR" "$ZIP_FILE" >/dev/null 2>&1 || true

# 🧩 ایجاد دایرکتوری جدید
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# 📄 فایل‌های لازم را ایجاد کن
echo "[2/7] Creating files..."
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  dnsmasq dnsutils curl jq python3 python3-flask cron ca-certificates && \
  rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY dnsmasq.conf.template /app/dnsmasq.conf.template
COPY update-ips.sh /app/update-ips.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY webview.py /app/webview.py
RUN chmod +x /app/*.sh
RUN (crontab -l 2>/dev/null; echo "0 */12 * * * /app/update-ips.sh >> /var/log/xbox-smartdns-update.log 2>&1") | crontab -
EXPOSE 53/udp
EXPOSE 4176/tcp
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

cat > docker-compose.yml <<'EOF'
services:
  xbox-smartdns:
    build: .
    container_name: xbox-smartdns-hybrid
    cap_add:
      - NET_ADMIN
    ports:
      - "53:53/udp"
      - "4176:4176/tcp"
    environment:
      - SMARTDNS_USER=YouneX
      - SMARTDNS_PASS=@YouneS@1365
    restart: unless-stopped
EOF

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
    local country=$(curl -s "https://ip-api.com/json/$ip?fields=countryCode" | jq -r '.countryCode')
    echo "$country"
}

resolve_best_ip() {
    local domain=$1
    local target_country=$2
    local ips=$(dig +short $domain | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    local best_ip=""
    for ip in $ips; do
        country=$(get_country "$ip")
        if [ "$country" == "$target_country" ]; then
            best_ip="$ip"; break
        fi
    done
    [ -z "$best_ip" ] && best_ip=$(echo "$ips" | head -n 1)
    echo "$best_ip"
}

log "Starting hybrid update..."
echo "# Auto-generated DNSMasq config" > "$DNSMASQ_CONF"
total=0

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

cat > webview.py <<'EOF'
from flask import Flask, request, redirect, url_for, session, render_template_string
import subprocess, functools, os
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = "xbox-smartdns-secret"

USER = "YouneX"
PASS = "@YouneS@1365"
PASSWORD_HASH = generate_password_hash(PASS)

TEMPLATE = """<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><title>Xbox SmartDNS Panel</title>
<style>body{background:#121212;color:#f0f0f0;text-align:center;font-family:sans-serif;}
.container{max-width:900px;margin:30px auto;padding:20px;background:#1e1e1e;border-radius:8px;}
textarea{width:100%;height:360px;background:#000;color:#0f0;font-family:monospace;font-size:13px;border-radius:5px;padding:10px;}
button{background-color:#00bfa5;border:none;color:white;padding:10px 20px;margin-top:10px;border-radius:5px;cursor:pointer;font-size:16px;}
button:hover{background-color:#00e0b0;}.logout{background:#d32f2f;}</style></head>
<body><div class="container"><h2>Xbox SmartDNS Panel</h2>
<p>Logged in as: {{ user }}</p><form method="post" action="/update"><button>Update IPs Now</button></form>
<h3>Latest Logs</h3><textarea readonly>{{ logs }}</textarea>
<form method="post" action="/logout"><button class="logout">Logout</button></form></div></body></html>"""

LOGIN_TEMPLATE = """<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Login</title>
<style>body{background:#121212;color:#f0f0f0;text-align:center;font-family:sans-serif;}
.login-box{background:#1e1e1e;border-radius:8px;padding:30px;margin:100px auto;width:320px;}
input{width:90%;padding:10px;margin:10px 0;border-radius:5px;border:1px solid #444;background:#000;color:#0f0;}
button{background:#00bfa5;border:none;color:white;padding:10px 20px;border-radius:5px;cursor:pointer;font-size:16px;}
button:hover{background:#00e0b0;}</style></head><body><div class="login-box">
<h2>SmartDNS Login</h2><form method="post">
<input name="username" placeholder="Username" required><br>
<input name="password" type="password" placeholder="Password" required><br>
<button type="submit">Login</button></form>{% if error %}<p style="color:#f44336;">{{ error }}</p>{% endif %}
</div></body></html>"""

def login_required(f):
    @functools.wraps(f)
    def wrapper(*a,**k):
        if session.get("logged_in"): return f(*a,**k)
        return redirect(url_for("login"))
    return wrapper

@app.route("/login", methods=["GET","POST"])
def login():
    error=None
    if request.method=="POST":
        u=request.form.get("username"); p=request.form.get("password")
        if u!=USER or not check_password_hash(PASSWORD_HASH,p): error="Invalid credentials"
        else:
            session["logged_in"]=True; session["user"]=u; return redirect(url_for("index"))
    return render_template_string(LOGIN_TEMPLATE,error=error)

@app.route("/logout",methods=["POST"])
def logout(): session.clear(); return redirect(url_for("login"))

@app.route("/")
@login_required
def index():
    log_file="/var/log/xbox-smartdns-update.log"
    logs=open(log_file,"r",encoding="utf-8",errors="ignore").read()[-8000:] if os.path.exists(log_file) else "No logs yet."
    return render_template_string(TEMPLATE,user=session.get("user"),logs=logs)

@app.route("/update",methods=["POST"])
@login_required
def update(): subprocess.Popen(["/app/update-ips.sh"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); return redirect(url_for("index"))
app.run(host="0.0.0.0",port=4176)
EOF

# 📦 زیپ کردن نسخه نهایی
cd /root
zip -rq "$ZIP_FILE" dns

# 🐳 اجرای Docker Compose
echo "[3/7] Building Docker image..."
cd "$BASE_DIR"
docker compose build

echo "[4/7] Starting container..."
docker compose up -d

sleep 5

echo "[5/7] Checking container logs..."
docker logs $CONTAINER_NAME --tail 15 || true

# ✅ نمایش اطلاعات دسترسی
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "✅ Deployment Complete!"
echo "--------------------------------"
echo "Panel URL:  http://$IP:4176"
echo "Username:   YouneX"
echo "Password:   @YouneS@1365"
echo "Logs:       docker logs -f $CONTAINER_NAME"
echo "--------------------------------"
echo "ZIP file saved at: $ZIP_FILE"
