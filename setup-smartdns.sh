#!/bin/bash
set -e

echo "🚀 راه‌اندازی SmartDNS برای Xbox با لاگ‌پنل..."

# مسیر کاری
WORKDIR="$HOME/dns"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# بررسی و نصب Docker
if ! command -v docker &> /dev/null; then
  echo "📦 Docker نصب نیست، در حال نصب..."
  apt update -y
  apt install -y ca-certificates curl gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
else
  echo "✅ Docker از قبل نصب شده است."
fi

# ایجاد فایل‌ها
echo "🧱 در حال ساخت فایل‌های پیکربندی..."

cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y dnsmasq python3 python3-pip cron && pip install flask
WORKDIR /app
COPY dnsmasq.conf.template /app/dnsmasq.conf.template
COPY update-ips.sh /app/update-ips.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY webview.py /app/webview.py
RUN chmod +x /app/*.sh
RUN (crontab -l 2>/dev/null; echo "0 */6 * * * /app/update-ips.sh >> /var/log/xbox-smartdns-update.log 2>&1") | crontab -
EXPOSE 53/udp 53/tcp 4176
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

cat > docker-compose.yml <<'EOF'
services:
  dns-xbox-smartdns:
    build: .
    container_name: xbox-smartdns-hybrid
    restart: always
    ports:
      - "53:53/udp"
      - "53:53/tcp"
      - "4176:4176"
    volumes:
      - ./data:/var/log
EOF

cat > dnsmasq.conf.template <<'EOF'
no-resolv
server=8.8.8.8
server=1.1.1.1
log-queries
log-facility=/var/log/dnsmasq.log
EOF

cat > update-ips.sh <<'EOF'
#!/bin/bash
LOG_FILE="/var/log/xbox-smartdns-update.log"
echo "[$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')] Starting hybrid update..." >> $LOG_FILE
# تست DNS واقعی
for host in xbox.com live.com microsoft.com cdn.xbox.com; do
  dig +short $host >> $LOG_FILE
done
echo "[$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')] Update finished." >> $LOG_FILE
EOF

cat > entrypoint.sh <<'EOF'
#!/bin/bash
service cron start
python3 /app/webview.py &
dnsmasq --no-daemon --conf-file=/app/dnsmasq.conf.template
EOF

cat > webview.py <<'EOF'
from flask import Flask, render_template_string, redirect, request
import subprocess, os, base64

USERNAME = "admin"
PASSWORD = "12345"

app = Flask(__name__)

PAGE = """
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>SmartDNS Log Panel</title>
  <style>
    body { background-color:#121212; color:#eee; font-family:monospace; }
    .box { max-width:900px; margin:auto; margin-top:40px; padding:20px; background:#1e1e1e; border-radius:12px; }
    textarea { width:100%; height:400px; background:#000; color:#0f0; border:none; border-radius:8px; padding:10px; }
    button { background:#03a9f4; color:white; padding:10px 20px; border:none; border-radius:8px; cursor:pointer; }
  </style>
</head>
<body>
  <div class="box">
    <h2>SmartDNS Log Panel</h2>
    <form method="POST" action="/run">
      <button type="submit">Update IPs Now</button>
    </form>
    <h3>Latest Logs:</h3>
    <textarea readonly>{{ logs }}</textarea>
  </div>
</body>
</html>
"""

@app.before_request
def check_auth():
    auth = request.authorization
    if not auth or auth.username != USERNAME or auth.password != PASSWORD:
        return ("Auth required", 401, {"WWW-Authenticate": 'Basic realm="Login Required"'})

@app.route('/')
def index():
    log_file = "/var/log/xbox-smartdns-update.log"
    logs = open(log_file).read() if os.path.exists(log_file) else "No logs yet."
    return render_template_string(PAGE, logs=logs)

@app.route('/run', methods=['POST'])
def run():
    subprocess.Popen(["/app/update-ips.sh"])
    return redirect("/")
    
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=4176)
EOF

# اجرای Docker Compose
echo "🐳 ساخت و راه‌اندازی سرویس..."
docker compose down || true
docker compose up -d --build

echo "✅ راه‌اندازی کامل شد!"
echo "--------------------------------------"
echo "🌐 لاگ‌پنل:  http://<IP سرور>:4176"
echo "👤 یوزرنیم: YouneX"
echo "🔒 پسورد:   @YouneS@1365"
echo "--------------------------------------"
echo "🧪 تست اولیه DNS:"
dig @127.0.0.1 xbox.com | head -n 5

