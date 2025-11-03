#!/bin/bash
set -euo pipefail

INSTALL_DIR="/root/dns"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "=== Updating system ==="
apt-get update -y && apt-get upgrade -y

echo "=== Installing minimal prerequisites ==="
apt-get install -y curl jq dnsutils python3 python3-pip cron ca-certificates

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
      - "4176:4176/tcp"
    environment:
      - SMARTDNS_USER=YouneX
      - SMARTDNS_PASS=@YouneS@1365
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
EXPOSE 4176/tcp
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

# webview.py
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
button:hover{background-color:#00e0b0;}</style></head><body><div class="login-box">
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
        else: session["logged_in"]=True; session["user"]=u; return redirect(url_for("index"))
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

echo "=== Building and starting Docker container ==="
docker-compose build
docker-compose up -d

echo "=== Testing DNS resolution inside container ==="
dig_result=$(docker exec xbox-smartdns-hybrid dig +short xbox.com || echo "Failed")
echo "DNS test result for xbox.com: $dig_result"

echo "=== Deployment finished ==="
echo "Web panel: http://<server-ip>:4176 (Username: YouneX / Password: @YouneS@1365)"
