#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Summarizer-AI — DevSecOps Automation Script
#  Automatically installs & configures:
#    - SonarQube (self-hosted, port 9000)
#    - Falco (runtime security monitor)
#    - Dashboard (served via Nginx, port 8080)
#  Run by GitHub Actions after every deploy
# ═══════════════════════════════════════════════════════════════

set -e  # Exit on any error

GREEN='\033[0;32m'
AMBER='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✅ OK]${NC} $1"; }
warn()   { echo -e "${AMBER}[⚠️  WARN]${NC} $1"; }
error()  { echo -e "${RED}[❌ ERR]${NC} $1"; }
info()   { echo -e "${BLUE}[ℹ️  INFO]${NC} $1"; }
header() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── 1. SYSTEM PREREQUISITES ─────────────────────────────────────
header "📦 Installing System Prerequisites"

sudo apt-get update -qq
sudo apt-get install -y -qq \
  curl wget unzip git jq \
  openjdk-17-jdk \
  ca-certificates gnupg lsb-release

log "System prerequisites installed"

# ── 2. SONARQUBE ────────────────────────────────────────────────
header "📊 Setting Up SonarQube"

SONAR_VERSION="10.4.1.88267"
SONAR_DIR="/opt/sonarqube"
SONAR_ZIP="/tmp/sonarqube.zip"

if [ -d "$SONAR_DIR" ]; then
  log "SonarQube already installed at $SONAR_DIR"
else
  info "Downloading SonarQube $SONAR_VERSION..."
  wget -q "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONAR_VERSION}.zip" \
    -O "$SONAR_ZIP"

  info "Extracting SonarQube..."
  sudo unzip -q "$SONAR_ZIP" -d /opt/
  sudo mv "/opt/sonarqube-${SONAR_VERSION}" "$SONAR_DIR"
  rm -f "$SONAR_ZIP"
  log "SonarQube extracted to $SONAR_DIR"
fi

# Create sonarqube user if not exists
if ! id "sonarqube" &>/dev/null; then
  sudo adduser --system --no-create-home --group --disabled-login sonarqube
  log "sonarqube user created"
fi

sudo chown -R sonarqube:sonarqube "$SONAR_DIR"

# Set vm.max_map_count required by SonarQube/Elasticsearch
if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
  echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
  sudo sysctl -w vm.max_map_count=262144
  log "vm.max_map_count set to 262144"
fi

# Set file descriptors limit
if ! grep -q "sonarqube" /etc/security/limits.conf; then
  echo "sonarqube   -   nofile   65536" | sudo tee -a /etc/security/limits.conf
  echo "sonarqube   -   nproc    4096"  | sudo tee -a /etc/security/limits.conf
  log "File descriptor limits set"
fi

# Create systemd service for SonarQube
sudo tee /etc/systemd/system/sonarqube.service > /dev/null << 'SONAR_SERVICE'
[Unit]
Description=SonarQube Service
After=network.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
ExecReload=/opt/sonarqube/bin/linux-x86-64/sonar.sh restart
User=sonarqube
Group=sonarqube
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
SONAR_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable sonarqube

# Start SonarQube if not running
if sudo systemctl is-active --quiet sonarqube; then
  log "SonarQube already running"
else
  info "Starting SonarQube (takes ~60s to boot)..."
  sudo systemctl start sonarqube

  # Wait for SonarQube to be ready
  info "Waiting for SonarQube to be ready..."
  for i in $(seq 1 24); do
    sleep 5
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9000/api/system/status 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ]; then
      log "SonarQube is UP at http://localhost:9000"
      break
    fi
    info "Still starting... ($((i*5))s)"
  done
fi

# Auto-create SonarQube project via API
info "Configuring SonarQube project..."
sleep 5

# Wait until API responds
API_UP=false
for i in $(seq 1 12); do
  HEALTH=$(curl -s "http://localhost:9000/api/system/status" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "DOWN")
  if [ "$HEALTH" = "UP" ]; then
    API_UP=true
    break
  fi
  sleep 5
done

if [ "$API_UP" = "true" ]; then
  # Create project
  curl -s -u admin:admin -X POST \
    "http://localhost:9000/api/projects/create" \
    -d "name=Summarizer-AI&project=summarizer-ai" > /dev/null 2>&1 || true

  # Generate user token for GitHub Actions
  TOKEN_RESPONSE=$(curl -s -u admin:admin -X POST \
    "http://localhost:9000/api/user_tokens/generate" \
    -d "name=github-actions-token" 2>/dev/null || echo '{}')

  SONAR_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token' 2>/dev/null || echo "")

  if [ -n "$SONAR_TOKEN" ] && [ "$SONAR_TOKEN" != "null" ]; then
    # Save token to file for pipeline to read
    echo "$SONAR_TOKEN" | sudo tee /opt/sonarqube/.github-actions-token > /dev/null
    sudo chmod 640 /opt/sonarqube/.github-actions-token
    sudo chown ubuntu:ubuntu /opt/sonarqube/.github-actions-token
    log "SonarQube token saved to /opt/sonarqube/.github-actions-token"
    log "Add this as SONAR_TOKEN in GitHub Secrets: $SONAR_TOKEN"
  else
    warn "Token already exists or project already created — skipping"
  fi

  log "SonarQube project 'summarizer-ai' ready"
else
  warn "SonarQube API not responding — check: sudo systemctl status sonarqube"
fi

# ── 3. FALCO ─────────────────────────────────────────────────────
header "👁️  Setting Up Falco"

if command -v falco &>/dev/null; then
  log "Falco already installed: $(falco --version 2>/dev/null | head -1)"
else
  info "Installing Falco..."

  # Add Falco repo
  curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] \
    https://download.falco.org/packages/deb stable main" \
    | sudo tee /etc/apt/sources.list.d/falcosecurity.list

  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y falco
  log "Falco installed"
fi

# Write custom Falco rules for Summarizer-AI
sudo mkdir -p /etc/falco/rules.d
sudo tee /etc/falco/rules.d/summarizer-ai.yaml > /dev/null << 'FALCO_RULES'
# ── Summarizer-AI Custom Falco Rules ──────────────────────────────

- rule: Unauthorized Write to Web Directory
  desc: Detect unexpected writes to Summarizer-AI web root
  condition: >
    open_write and
    fd.directory startswith "/var/www/Summarizer-AI" and
    not proc.name in (nginx, scp, sftp-server, sh, bash)
  output: >
    UNAUTHORIZED WRITE to web dir
    (user=%user.name proc=%proc.name file=%fd.name cmd=%proc.cmdline)
  priority: WARNING
  tags: [filesystem, web, summarizer-ai]

- rule: Reverse Shell Attempt Detected
  desc: Detect potential reverse shell on the server
  condition: >
    spawned_process and
    proc.name in (bash, sh, dash, nc, ncat, netcat, nsh) and
    (proc.args contains ">/dev/tcp" or proc.args contains "mkfifo")
  output: >
    REVERSE SHELL ATTEMPT
    (user=%user.name proc=%proc.name args=%proc.args container=%container.name)
  priority: CRITICAL
  tags: [shell, attack, summarizer-ai]

- rule: Network Recon Tool Detected
  desc: Detect use of network scanning/recon tools
  condition: >
    spawned_process and
    proc.name in (nmap, masscan, zmap, nikto, sqlmap, hydra, gobuster)
  output: >
    NETWORK RECON TOOL USED
    (user=%user.name proc=%proc.name args=%proc.args)
  priority: WARNING
  tags: [network, recon, summarizer-ai]

- rule: Sensitive File Access Attempt
  desc: Detect attempts to read sensitive files
  condition: >
    open_read and
    fd.name in (/etc/shadow, /etc/passwd, /root/.ssh/id_rsa,
                /home/ubuntu/.ssh/id_rsa, /opt/sonarqube/.github-actions-token)
    and not proc.name in (sshd, sudo, su, cat, grep)
  output: >
    SENSITIVE FILE ACCESS
    (user=%user.name proc=%proc.name file=%fd.name)
  priority: CRITICAL
  tags: [filesystem, credentials, summarizer-ai]

- rule: Cryptominer Behavior Detected
  desc: Detect potential cryptomining activity
  condition: >
    spawned_process and
    (proc.name in (xmrig, minerd, cpuminer) or
     proc.args contains "stratum+tcp" or
     proc.args contains "pool.supportxmr.com")
  output: >
    CRYPTOMINER DETECTED
    (user=%user.name proc=%proc.name args=%proc.args)
  priority: CRITICAL
  tags: [cryptominer, attack, summarizer-ai]
FALCO_RULES

log "Custom Falco rules written"

# Configure Falco to write JSON logs for dashboard
sudo tee /etc/falco/falco_local.yaml > /dev/null << 'FALCO_CONFIG'
json_output: true
json_include_output_property: true
log_level: info
log_stderr: true
log_syslog: true
output_timeout: 2000
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco/falco.log
FALCO_CONFIG

sudo mkdir -p /var/log/falco
sudo chmod 755 /var/log/falco

# Enable and start Falco
sudo systemctl daemon-reload
sudo systemctl enable falco 2>/dev/null || \
sudo systemctl enable falco-kmod 2>/dev/null || true

sudo systemctl restart falco 2>/dev/null || \
sudo systemctl restart falco-kmod 2>/dev/null || true

sleep 2

if sudo systemctl is-active --quiet falco 2>/dev/null || \
   sudo systemctl is-active --quiet falco-kmod 2>/dev/null; then
  log "Falco is running and monitoring"
else
  warn "Falco service not active — may need kernel module. Check: sudo systemctl status falco"
fi

# ── 4. NGINX SECURITY HARDENING ──────────────────────────────────
header "🔒 Applying Nginx Security Hardening"

NGINX_CONF="/etc/nginx/sites-available/default"

# Block .git
if ! sudo grep -q "location ~ /\\.git" "$NGINX_CONF"; then
  sudo sed -i '/server_name _;/a\\n\tlocation ~ /\\.git {\n\t\tdeny all;\n\t\treturn 404;\n\t}' "$NGINX_CONF"
  log ".git access blocked"
fi

# Security headers
if ! sudo grep -q "X-Frame-Options" "$NGINX_CONF"; then
  sudo sed -i '/server_name _;/a\\tadd_header X-Frame-Options "SAMEORIGIN" always;\n\tadd_header X-Content-Type-Options "nosniff" always;\n\tadd_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;' "$NGINX_CONF"
  log "Security headers added"
fi

sudo nginx -t && sudo systemctl reload nginx
log "Nginx reloaded with hardened config"

# ── 5. DASHBOARD API — Falco log endpoint ────────────────────────
header "📡 Setting Up Dashboard Log API"

# Simple Python API to serve Falco logs to dashboard
sudo tee /opt/falco-api.py > /dev/null << 'FALCO_API'
#!/usr/bin/env python3
"""Minimal Falco log API for DevSecOps Dashboard"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os

class FalcoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()

        if self.path == '/falco/events':
            try:
                result = subprocess.run(
                    ['sudo', 'tail', '-n', '50', '/var/log/falco/falco.log'],
                    capture_output=True, text=True, timeout=5
                )
                lines = [l for l in result.stdout.strip().split('\n') if l]
                events = []
                for line in lines:
                    try:
                        events.append(json.loads(line))
                    except:
                        events.append({'output': line, 'priority': 'notice', 'time': ''})
                self.wfile.write(json.dumps({'events': events[-20:]}).encode())
            except Exception as e:
                self.wfile.write(json.dumps({'events': [], 'error': str(e)}).encode())

        elif self.path == '/sonar/status':
            try:
                import urllib.request
                with urllib.request.urlopen('http://localhost:9000/api/system/status', timeout=3) as r:
                    data = json.loads(r.read())
                self.wfile.write(json.dumps(data).encode())
            except Exception as e:
                self.wfile.write(json.dumps({'status': 'DOWN', 'error': str(e)}).encode())

        elif self.path == '/health':
            self.wfile.write(json.dumps({'status': 'ok'}).encode())
        else:
            self.wfile.write(json.dumps({'error': 'not found'}).encode())

    def log_message(self, format, *args): pass  # suppress access logs

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8081), FalcoHandler)
    print('Falco API running on port 8081')
    server.serve_forever()
FALCO_API

sudo chmod +x /opt/falco-api.py

# Create systemd service for Falco API
sudo tee /etc/systemd/system/falco-api.service > /dev/null << 'API_SERVICE'
[Unit]
Description=Falco Dashboard API
After=network.target falco.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/falco-api.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
API_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable falco-api
sudo systemctl restart falco-api
sleep 1

if sudo systemctl is-active --quiet falco-api; then
  log "Falco API running on port 8081"
else
  warn "Falco API not started — check: sudo systemctl status falco-api"
fi

# ── 6. FINAL STATUS ──────────────────────────────────────────────
header "🎉 Setup Complete — Service Status"

echo ""
echo -e "  📊 SonarQube   → http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_EC2_IP'):9000"
echo -e "  👁️  Falco Logs  → sudo journalctl -u falco -f"
echo -e "  📡 Falco API   → http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_EC2_IP'):8081/falco/events"
echo -e "  🔒 Nginx       → Hardened & reloaded"
echo ""

if [ -f /opt/sonarqube/.github-actions-token ]; then
  echo -e "  🔑 SONAR_TOKEN     = $(cat /opt/sonarqube/.github-actions-token)"
  echo -e "  🔑 SONAR_HOST_URL  = http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_EC2_IP'):9000"
  echo ""
  echo -e "  ⚠️  Add these 2 values as GitHub Secrets!"
fi

echo ""
