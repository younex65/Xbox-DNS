#!/bin/bash
set -euo pipefail

INSTALL_DIR="/root/dns"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "=== Updating system ==="
apt-get update -y && apt-get upgrade -y

echo "=== Installing prerequisites ==="
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

# ---------- webview.py نهایی با modal و رنگ‌ها ----------
cat > webview.py <<'EOF'
#!/usr/bin/env python3
# webview.py — modernized UI with modal change-password, confirm password, colored logs, consistent buttons, solid turquoise buttons
from flask import Flask, request, redirect, url_for, session, render_template_string, jsonify
import subprocess, functools, os, re, html
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = "xbox-smartdns-secret"

CONFIG_PATH = "/app/config.env"
LOG_FILE = "/var/log/xbox-smartdns-update.log"

def load_credentials():
    user, pwd = "admin", "123456"
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            for line in f:
                if line.startswith("SMARTDNS_USER="): user = line.strip().split("=",1)[1]
                elif line.startswith("SMARTDNS_PASS="): pwd = line.strip().split("=",1)[1]
    return user, pwd

def save_credentials(u, p):
    with open(CONFIG_PATH, "w") as f:
        f.write(f"SMARTDNS_USER={u}\nSMARTDNS_PASS={p}\n")

USER, PASS = load_credentials()
PASSWORD_HASH = generate_password_hash(PASS)

def read_logs(max_chars=12000):
    if not os.path.exists(LOG_FILE):
        return "No logs yet."
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()[-max_chars:]
            return content
    except Exception as e:
        return f"Error reading logs: {e}"

def escape_and_colorize(raw):
    text = html.escape(raw)
    text = re.sub(r'(\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\])', r'<span class="ts">\1</span>', text)
    text = re.sub(r'(Resolved [^\n]+→ [0-9\.]+(?: \([A-Z]{2}\))?)', r'<span class="resolved">\1</span>', text)
    text = re.sub(r'(Starting hybrid update\.\.\.|Update finished\.)', r'<span class="info">\1</span>', text)
    text = re.sub(r'\bERROR\b', r'<span class="err">ERROR</span>', text)
    text = re.sub(r'\bFailed\b', r'<span class="err">Failed</span>', text)
    text = re.sub(r'((?:\d{1,3}\.){3}\d{1,3})', r'<span class="ip">\1</span>', text)
    text = text.replace("\n", "<br>")
    return text

# ---------- main HTML template ----------
TEMPLATE = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Xbox SmartDNS Panel</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{
  --bg:#0f1720; --card:#0b1220; --muted:#9aa4b2; --accent:#00c8b8; --danger:#ff6b6b; --glass: rgba(255,255,255,0.03);
  --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, "Roboto Mono", "Courier New", monospace;
}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#071021 0%,var(--bg) 100%);color:#e6eef6;font-family:Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial;}
.container{max-width:980px;margin:28px auto;padding:20px;background:linear-gradient(180deg, rgba(255,255,255,0.02), rgba(255,255,255,0.01));border-radius:12px;box-shadow:0 6px 24px rgba(2,6,23,0.6);border:1px solid rgba(255,255,255,0.03);}
.header{display:flex;gap:12px;align-items:center;justify-content:space-between;}
.brand{display:flex;gap:12px;align-items:center;}
.logo{width:44px;height:44px;border-radius:10px;background:var(--accent);display:flex;align-items:center;justify-content:center;font-weight:700;color:#021;box-shadow:0 6px 18px rgba(0,0,0,0.5);}
.title{font-size:20px;font-weight:600;}
.controls{display:flex;gap:10px;align-items:center;}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:10px 14px;border-radius:10px;border:none;cursor:pointer;font-weight:600; min-width:140px;}
.btn:active{transform:translateY(1px)}
.btn.secondary{background:var(--accent);color:#012a2a;}
.btn.primary{background:var(--accent);color:#012a2a;}
.btn.ghost{background:transparent;border:1px dashed rgba(255,255,255,0.04);color:var(--muted); min-width:110px;}
.btn.logout{background:var(--danger);color:#fff; min-width:110px;}
.row{display:flex;gap:12px;margin-top:18px;align-items:flex-start;}
.card{flex:1;background:rgba(255,255,255,0.02);padding:14px;border-radius:10px;border:1px solid rgba(255,255,255,0.02);}
.card h3{margin:0 0 8px 0;font-size:16px}
.logs {height:420px; overflow:auto; background:#02040a; border-radius:8px; padding:12px; font-family:var(--mono); font-size:13px; line-height:1.45; color:#bfe8c9; border:1px solid rgba(255,255,255,0.02);}
.controls .small {padding:8px 10px;}
.info{color:#89d4ff}
.resolved{color:#b6f0c9}
.err{color:#ff8b8b;font-weight:700}
.ip{color:#ffd89b}
.ts{color:#9bb4ff;font-size:12px}
.footer{margin-top:12px;font-size:13px;color:var(--muted);text-align:right}
.link{color:var(--accent);text-decoration:none}
.center{display:flex;align-items:center;justify-content:center}

.modal-backdrop{position:fixed;inset:0;background:rgba(2,6,23,0.6);display:none;align-items:center;justify-content:center;padding:20px}
.modal{width:100%;max-width:420px;background:linear-gradient(180deg,#08121a, #07111a);padding:18px;border-radius:12px;border:1px solid rgba(255,255,255,0.02);box-shadow:0 10px 30px rgba(2,6,23,0.7)}
.form-row{display:flex;flex-direction:column;gap:8px;margin-bottom:8px}
.input{background:#041122;border-radius:8px;padding:10px;border:1px solid rgba(255,255,255,0.03);color:#d7eefb;width:100%}
.err-text{color:var(--danger);font-weight:700;margin-top:8px}
@media (max-width:720px){ .row{flex-direction:column} .controls{flex-direction:column;align-items:stretch} }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="brand">
      <div class="logo">SD</div>
      <div>
        <div class="title">Xbox SmartDNS Panel</div>
        <div style="font-size:12px;color:#9aa4b2;">Logged in as: <strong>{{ user }}</strong></div>
      </div>
    </div>
    <div class="controls">
      <form method="post" action="/update" style="display:inline;">
        <button class="btn primary" type="submit">Update IPs Now</button>
      </form>
      <button id="openChange" class="btn secondary">Change Username / Password</button>
      <form method="post" action="/logout" style="display:inline;">
        <button class="btn logout" type="submit">Logout</button>
      </form>
    </div>
  </div>

  <div class="row">
    <div class="card" style="flex:1.4">
      <h3>Latest Logs</h3>
      <div id="logs" class="logs">{{ logs|safe }}</div>
      <div class="footer">Auto-refresh: Off · Showing latest ~12k chars</div>
    </div>

    <div class="card" style="flex:0.6">
      <h3>Quick Actions</h3>
      <div style="display:flex;flex-direction:column;gap:8px">
        <form method="post" action="/update" style="display:inline;">
          <button class="btn ghost small" type="submit">Run Update (background)</button>
        </form>
        <a class="link" href="#" onclick="downloadLogs()">Download logs</a>
        <div style="font-size:12px;color:#9aa4b2;">You will be logged out after changing credentials. Please remember your new password.</div>
      </div>
    </div>
  </div>
</div>

<div id="modalBk" class="modal-backdrop">
  <div class="modal" role="dialog" aria-modal="true">
    <h3 style="margin-top:0">Change Credentials</h3>
    <div class="form-row">
      <input id="new_user" class="input" placeholder="New username" />
    </div>
    <div class="form-row">
      <input id="new_pass" class="input" type="password" placeholder="New password" />
      <input id="new_pass_confirm" class="input" type="password" placeholder="Confirm new password" />
      <div id="modalErr" class="err-text" style="display:none"></div>
    </div>
    <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:8px">
      <button id="modalCancel" class="btn secondary">Cancel</button>
      <button id="modalSave" class="btn primary">Save</button>
    </div>
  </div>
</div>

<script>
const modalBk = document.getElementById("modalBk");
const openChange = document.getElementById("openChange");
const modalCancel = document.getElementById("modalCancel");
const modalSave = document.getElementById("modalSave");
const modalErr = document.getElementById("modalErr");

openChange.onclick = ()=> { modalBk.style.display='flex'; modalErr.style.display='none'; }
modalCancel.onclick = ()=> { modalBk.style.display='none'; }

modalSave.onclick = async ()=>{
  modalErr.style.display='none';
  const new_user = document.getElementById("new_user").value.trim();
  const new_pass = document.getElementById("new_pass").value;
  const new_pass_confirm = document.getElementById("new_pass_confirm").value;
  if(!new_user || !new_pass){ modalErr.textContent="Username and password are required."; modalErr.style.display='block'; return; }
  if(new_pass !== new_pass_confirm){ modalErr.textContent="Passwords do not match."; modalErr.style.display='block'; return; }

  try{
    const resp = await fetch("/change-password", {
      method:"POST",
      headers:{"Content-Type":"application/json"},
      body: JSON.stringify({new_user, new_pass})
    });
    const j = await resp.json();
    if(j && j.success){ window.location.href = "/login"; }
    else { modalErr.textContent = j.error || "Unknown error"; modalErr.style.display='block'; }
  }catch(e){ modalErr.textContent = "Network error: "+e; modalErr.style.display='block'; }
}

const logsEl = document.getElementById("logs");
if(logsEl) logsEl.scrollTop = logsEl.scrollHeight;

function downloadLogs(){
  fetch("/download-logs").then(r=>r.blob()).then(blob=>{
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "xbox-smartdns-update.log";
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  }).catch(e=>alert("Failed to download: "+e));
}
</script>
</body>
</html>
"""

# ---------- login template ----------
LOGIN_TEMPLATE = """<!doctype html><html><head><meta charset="utf-8"><title>Login</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{background:linear-gradient(180deg,#071021,#081426);color:#eaf6ff;font-family:Inter,system-ui, -apple-system, 'Segoe UI', Roboto, Arial;}
.center{display:flex;align-items:center;justify-content:center;height:100vh}
.box{background:linear-gradient(180deg, rgba(255,255,255,0.02), rgba(255,255,255,0.01));padding:28px;border-radius:12px;box-shadow:0 10px 30px rgba(2,6,23,0.6);width:340px}
.input{width:100%;padding:10px;margin:8px 0;border-radius:8px;border:1px solid rgba(255,255,255,0.03);background:#041022;color:#dff6ff}
.btn{width:100%;padding:10px;border-radius:10px;border:none;background:#00c8b8;color:#012a2a;font-weight:700}
.err{color:#ff8b8b;margin-top:8px}
.small{color:#9bb3c6;font-size:13px;margin-top:8px}
</style></head><body>
<div class="center">
  <div class="box">
    <h2 style="margin:0 0 8px 0">SmartDNS Login</h2>
    <form method="post">
      <input class="input" name="username" placeholder="Username" required>
      <input class="input" type="password" name="password" placeholder="Password" required>
      <button class="btn" type="submit">Login</button>
    </form>
    {% if error %}<div class="err">{{ error }}</div>{% endif %}
    <div class="small">Default: admin / 123456 (change after first login)</div>
  </div>
</div>
</body>
</html>"""

def login_required(f):
    @functools.wraps(f)
    def wrapper(*a,**k):
        if session.get("logged_in"): return f(*a,**k)
        return redirect(url_for("login"))
    return wrapper

@app.route("/login", methods=["GET","POST"])
def login():
    global USER, PASS, PASSWORD_HASH
    error=None
    if request.method=="POST":
        u = request.form.get("username","")
        p = request.form.get("password","")
        if u != USER or not check_password_hash(PASSWORD_HASH, p):
            error="Invalid credentials"
        else:
            session["logged_in"]=True
            session["user"]=u
            return redirect(url_for("index"))
    return render_template_string(LOGIN_TEMPLATE, error=error)

@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
@login_required
def index():
    raw = read_logs()
    colored = escape_and_colorize(raw)
    return render_template_string(TEMPLATE, user=session.get("user"), logs=colored)

@app.route("/update", methods=["POST"])
@login_required
def update():
    try:
        subprocess.Popen(["/app/update-ips.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    return redirect(url_for("index"))

@app.route("/change-password", methods=["POST"])
@login_required
def change_password():
    global USER, PASS, PASSWORD_HASH
    try:
        data = request.get_json() or {}
        new_user = (data.get("new_user") or "").strip()
        new_pass = data.get("new_pass") or ""
        if not new_user or not new_pass:
            return jsonify({"success": False, "error": "Username and password required"}), 400
        save_credentials(new_user, new_pass)
        USER = new_user
        PASS = new_pass
        PASSWORD_HASH = generate_password_hash(PASS)
        session.clear()
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

@app.route("/download-logs", methods=["GET"])
@login_required
def download_logs():
    if not os.path.exists(LOG_FILE):
        return "No logs", 404
    return (open(LOG_FILE, "rb").read(), 200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': 'attachment; filename="xbox-smartdns-update.log"'
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=4000)

EOF

echo "=== Building and starting Docker container ==="
docker-compose build
docker-compose up -d

echo "=== DNS test ==="
docker exec xbox-smartdns-hybrid dig +short xbox.com || echo "DNS test failed"

echo "=== Setup complete ==="
echo "Web panel: http://<server-ip>:4000"
echo "Default login → Username: admin | Password: 123456"
