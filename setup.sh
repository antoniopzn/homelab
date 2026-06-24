#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  HOMELAB DEBIAN 13 — INSTALAÇÃO AUTOMÁTICA COMPLETA
#  Uso: chmod +x setup.sh && sudo ./setup.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ─────────────────────────────────────────────
#  🎨 CORES
# ─────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; M='\033[0;35m'; C='\033[0;36m'
W='\033[0m'; BD='\033[1m'; DIM='\033[2m'

# ─────────────────────────────────────────────
#  ⚙️  CONFIGURAÇÃO — EDITE ANTES DE RODAR
# ─────────────────────────────────────────────
DOMAIN="seudominio.com"          # Seu domínio no Cloudflare
DEPLOY_USER="deploy"             # Usuário principal
DEPLOY_PASS=""                   # Deixe vazio para gerar automaticamente
COCKPIT_PASS=""                  # Senha do Cockpit (vazio = automática)
FILEBROWSER_PASS=""              # Senha do FileBrowser (vazio = automática)
CODESERVER_PASS=""               # Senha do Code-Server (vazio = automática)
DB_PASS=""                       # Senha dos bancos (vazio = automática)
TUNNEL_NAME="homelab"            # Nome do tunnel no Cloudflare
TZ="America/Sao_Paulo"           # Timezone
SSH_KEY=""                       # Cole sua chave SSH pública (vazio = pula)

# ─────────────────────────────────────────────
#  📁 CAMINHOS
# ─────────────────────────────────────────────
LOG_FILE="/var/log/homelab-setup.log"
SCRIPT_DIR="/home/${DEPLOY_USER}/scripts"
APPS_DIR="/home/${DEPLOY_USER}/apps"
BACKUP_DIR="/home/${DEPLOY_USER}/backups"
LOGS_DIR="/home/${DEPLOY_USER}/logs"

# ─────────────────────────────────────────────
#  🔧 FUNÇÕES AUXILIARES
# ─────────────────────────────────────────────
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"; shift
    local msg="[$(timestamp)] [$level] $*"
    echo -e "${msg}" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "${C}$*${W}"; }
ok()    { log "OK"    "${G}✅ $*${W}"; }
warn()  { log "WARN"  "${Y}⚠️  $*${W}"; }
err()   { log "ERROR" "${R}❌ $*${W}"; }
step()  { echo -e "\n${BD}${M}━━━ $* ━━━${W}\n" | tee -a "$LOG_FILE"; }

gen_pass() {
    openssl rand -base64 16 | tr -d '/+=' | head -c 20
}

confirm() {
    local msg="$1"
    echo -ne "${Y}${msg} [s/N] ${W}"
    read -r resp
    [[ "$resp" =~ ^[SsYy]$ ]]
}

check_cmd() {
    command -v "$1" &>/dev/null
}

# ─────────────────────────────────────────────
#  🛡️  VALIDAÇÕES INICIAIS
# ─────────────────────────────────────────────
preflight() {
    step "PRÉ-CHECK"

    if [ "$(id -u)" -ne 0 ]; then
        err "Execute como root: sudo $0"
        exit 1
    fi
    ok "Rodando como root"

    if [ ! -f /etc/debian_version ]; then
        err "Este script é para Debian apenas"
        exit 1
    fi
    local ver
    ver=$(cat /etc/debian_version | cut -d. -f1)
    info "Debian versão detectada: $ver"
    ok "Sistema compatível"

    if ! ping -c1 -W3 1.1.1.1 &>/dev/null; then
        err "Sem conexão com a internet"
        exit 1
    fi
    ok "Internet disponível"

    # Gerar senhas se necessário
    [ -z "$DEPLOY_PASS" ]      && DEPLOY_PASS=$(gen_pass)
    [ -z "$COCKPIT_PASS" ]     && COCKPIT_PASS=$(gen_pass)
    [ -z "$FILEBROWSER_PASS" ] && FILEBROWSER_PASS=$(gen_pass)
    [ -z "$CODESERVER_PASS" ]  && CODESERVER_PASS=$(gen_pass)
    [ -z "$DB_PASS" ]          && DB_PASS=$(gen_pass)

    info "Senhas geradas automaticamente (serão salvas ao final)"

    # Criar diretório de log
    mkdir -p "$(dirname "$LOG_FILE")"
}

# ─────────────────────────────────────────────
#  1️⃣  ATUALIZAÇÃO DO SISTEMA
# ─────────────────────────────────────────────
sys_update() {
    step "1/12 — ATUALIZAÇÃO DO SISTEMA"

    export DEBIAN_FRONTEND=noninteractive

    apt update -y 2>&1 | tee -a "$LOG_FILE" | tail -1
    apt full-upgrade -y 2>&1 | tee -a "$LOG_FILE" | tail -1
    apt autoremove -y 2>&1 | tee -a "$LOG_FILE" | tail -1

    timedatectl set-timezone "$TZ"
    ok "Sistema atualizado e timezone configurada"
}

# ─────────────────────────────────────────────
#  2️⃣  PACOTES ESSENCIAIS
# ─────────────────────────────────────────────
install_basics() {
    step "2/12 — PACOTES ESSENCIAIS"

    apt install -y curl wget git unzip jq htop tmux \
        ufw fail2ban \
        nginx \
        build-essential libssl-dev pkg-config \
        gnupg lsb-release \
        sqlite3 ca-certificates \
        2>&1 | tail -1

    ok "Pacotes essenciais instalados"
}

# ─────────────────────────────────────────────
#  3️⃣  USUÁRIO + SSH
# ─────────────────────────────────────────────
setup_user() {
    step "3/12 — USUÁRIO E SSH"

    if id "$DEPLOY_USER" &>/dev/null; then
        info "Usuário ${DEPLOY_USER} já existe"
    else
        useradd -m -s /bin/bash "$DEPLOY_USER"
        echo "${DEPLOY_USER}:${DEPLOY_PASS}" | chpasswd
        usermod -aG sudo "$DEPLOY_USER"
        ok "Usuário ${DEPLOY_USER} criado"
    fi

    # SSH hardened
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/hardened.conf << 'SSHEOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF

    # Adicionar AllowUsers só se não existir
    if ! grep -q "AllowUsers" /etc/ssh/sshd_config.d/hardened.conf; then
        echo "AllowUsers ${DEPLOY_USER}" >> /etc/ssh/sshd_config.d/hardened.conf
    fi

    # Chave SSH
    if [ -n "$SSH_KEY" ]; then
        mkdir -p "/home/${DEPLOY_USER}/.ssh"
        echo "$SSH_KEY" > "/home/${DEPLOY_USER}/.ssh/authorized_keys"
        chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
        chmod 700 "/home/${DEPLOY_USER}/.ssh"
        chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
        ok "Chave SSH configurada"
    else
        warn "Nenhuma chave SSH fornecida — SSH por senha continua desabilitado"
        warn "Adicione sua chave depois: ssh-copy-id ${DEPLOY_USER}@IP_DO_SERVIDOR"
    fi

    systemctl restart sshd
    ok "SSH hardening aplicado"
}

# ─────────────────────────────────────────────
#  4️⃣  FIREWALL + SEGURANÇA
# ─────────────────────────────────────────────
setup_security() {
    step "4/12 — FIREWALL E SEGURANÇA"

    # UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 7844/tcp

    # Portas internas (localhost only)
    ufw allow in on lo to any port 9090
    ufw allow in on lo to any port 8088
    ufw allow in on lo to any port 8443
    ufw allow in on lo to any port 19999
    ufw allow in on lo to any port 80
    ufw allow in on lo to any port 443

    ufw --force enable
    ok "UFW configurado"

    # Fail2ban
    cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
F2BEOF
    systemctl enable fail2ban --now
    ok "Fail2ban ativo"

    # CrowdSec
    if check_cmd cscli; then
        cscli collections install crowdsecurity/linux 2>/dev/null || true
        cscli collections install crowdsecurity/sshd 2>/dev/null || true
        systemctl enable crowdsec --now
        ok "CrowdSec ativo"
    else
        warn "CrowdSec não encontrado — pulando (instale manualmente se desejar)"
    fi

    # Desabilitar IPv6 se não usado (reduz superfície)
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.d/99-homelab.conf 2>/dev/null; then
        cat > /etc/sysctl.d/99-homelab.conf << 'SYSEOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
        sysctl --system &>/dev/null
    fi
    ok "Segurança configurada"
}

# ─────────────────────────────────────────────
#  5️⃣  COCKPIT
# ─────────────────────────────────────────────
install_cockpit() {
    step "5/12 — COCKPIT (PAINEL PRINCIPAL)"

    apt install -y cockpit cockpit-storaged cockpit-networkmanager \
        cockpit-packagekit cockpit-terminal cockpit-sosreport \
        2>&1 | tee -a "$LOG_FILE" | tail -1

    mkdir -p /etc/cockpit
    cat > /etc/cockpit/cockpit.conf << 'CPTEOF'
[WebService]
ListenAddress = 127.0.0.1
Port = 9090
AllowUnencrypted = true
ProtocolHeader = X-Forwarded-Proto
ForwardedForHeader = X-Forwarded-For

[Session]
IdleTimeout = 900

[Log]
MaxLogSize = 10485760
CPTEOF

    systemctl enable cockpit.socket --now

    # Garantir que o usuário deploy pode logar no Cockpit
    echo "${DEPLOY_USER}:${COCKPIT_PASS}" | chpasswd

    sleep 2
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090 | grep -q "401"; then
        ok "Cockpit rodando em :9090"
    else
        warn "Cockpit pode não ter iniciado ainda — verifique com: systemctl status cockpit"
    fi
}

# ─────────────────────────────────────────────
#  6️⃣  FILEBROWSER
# ─────────────────────────────────────────────
install_filebrowser() {
    step "6/12 — FILEBROWSER (GERENCIADOR DE ARQUIVOS)"

    local fb_url
    fb_url=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest \
        | jq -r '.assets[] | select(.name == "linux-amd64-filebrowser.tar.gz") | .browser_download_url')

    if [ -z "$fb_url" ] || [ "$fb_url" = "null" ]; then
        err "Não consegui obter URL do FileBrowser"
        return 1
    fi

    curl -fsSL "$fb_url" | tar -xz -C /usr/local/bin filebrowser 2>&1
    chmod +x /usr/local/bin/filebrowser

    mkdir -p /etc/filebrowser /var/lib/filebrowser

    filebrowser config init \
        --database /var/lib/filebrowser/filebrowser.db \
        --noauth 2>/dev/null || true

    filebrowser config set --address 127.0.0.1
    filebrowser config set --port 8088
    filebrowser config set --root "/home/${DEPLOY_USER}"
    filebrowser config set --baseurl /

    filebrowser users add admin "$FILEBROWSER_PASS" --perm.admin 2>/dev/null || \
        filebrowser users update admin --password "$FILEBROWSER_PASS" 2>/dev/null || true

    cat > /etc/systemd/system/filebrowser.service << FBEEOF
[Unit]
Description=FileBrowser
After=network.target

[Service]
Type=simple
User=${DEPLOY_USER}
Group=${DEPLOY_USER}
ExecStart=/usr/local/bin/filebrowser -c /etc/filebrowser/settings.json
Restart=on-failure
RestartSec=5
Environment=HOME=/home/${DEPLOY_USER}

[Install]
WantedBy=multi-user.target
FBEEOF

    # Mover config se foi gerada em outro lugar
    [ -f /home/${DEPLOY_USER}/settings.json ] && \
        mv /home/${DEPLOY_USER}/settings.json /etc/filebrowser/ 2>/dev/null || true
    [ -f /var/lib/filebrowser/settings.json ] && \
        cp /var/lib/filebrowser/settings.json /etc/filebrowser/ 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable filebrowser --now

    sleep 2
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8088 | grep -qE "200|301|302|401"; then
        ok "FileBrowser rodando em :8088"
    else
        warn "FileBrowser pode não ter iniciado — verifique: journalctl -u filebrowser"
    fi
}

# ─────────────────────────────────────────────
#  7️⃣  CODE-SERVER
# ─────────────────────────────────────────────
install_codeserver() {
    step "7/12 — CODE-SERVER (VS CODE WEB)"

    curl -fsSL https://code-server.dev/install.sh | sh 2>&1 | tee -a "$LOG_FILE" | tail -3

    mkdir -p "/home/${DEPLOY_USER}/.config/code-server"
    cat > "/home/${DEPLOY_USER}/.config/code-server/config.yaml" << CSEOF
bind-addr: 127.0.0.1:8443
auth: password
password: ${CODESERVER_PASS}
cert: false
CSEOF

    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.config"

    systemctl enable "code-server@${DEPLOY_USER}" --now

    sleep 3
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443 | grep -qE "200|301|302|401|403"; then
        ok "Code-Server rodando em :8443"
    else
        warn "Code-Server pode não ter iniciado — verifique: journalctl -u code-server@${DEPLOY_USER}"
    fi
}

# ─────────────────────────────────────────────
#  8️⃣  STACK DE PRODUÇÃO
# ─────────────────────────────────────────────
install_stack() {
    step "8/12 — STACK DE PRODUÇÃO (PHP + Node + Python + DBs)"

    # ── PHP ──
    local php_ver
    php_ver=$(php -v 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1,2)
    if [ -z "$php_ver" ]; then
        php_ver="8.3"
        apt install -y php${php_ver}-fpm php${php_ver}-cli php${php_ver}-common \
            php${php_ver}-mysql php${php_ver}-pgsql php${php_ver}-sqlite3 \
            php${php_ver}-redis php${php_ver}-mbstring php${php_ver}-xml \
            php${php_ver}-curl php${php_ver}-zip php${php_ver}-gd \
            php${php_ver}-intl php${php_ver}-bcmath php${php_ver}-imagick \
            php${php_ver}-opcache php${php_ver}-readline \
            2>&1 | tail -1
    else
        apt install -y php${php_ver}-fpm php${php_ver}-cli php${php_ver}-common \
            php${php_ver}-mysql php${php_ver}-pgsql php${php_ver}-sqlite3 \
            php${php_ver}-redis php${php_ver}-mbstring php${php_ver}-xml \
            php${php_ver}-curl php${php_ver}-zip php${php_ver}-gd \
            php${php_ver}-intl php${php_ver}-bcmath php${php_ver}-imagick \
            php${php_ver}-opcache php${php_ver}-readline \
            2>&1 | tail -1
    fi

    cat > "/etc/php/${php_ver}/fpm/pool.d/${DEPLOY_USER}.conf" << PHPEOF
[${DEPLOY_USER}]
user = ${DEPLOY_USER}
group = ${DEPLOY_USER}
listen = /run/php/php-${DEPLOY_USER}.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 20
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 500
php_admin_value[open_basedir] = /home/${DEPLOY_USER}:/tmp:/usr/share/php
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_flag[display_errors] = off
php_admin_value[error_log] = /var/log/php/${DEPLOY_USER}-error.log
php_admin_flag[log_errors] = on
PHPEOF

    mkdir -p /var/log/php
    systemctl enable "php${php_ver}-fpm" --now
    ok "PHP ${php_ver} instalado"

    # ── Node.js 22 ──
    if ! check_cmd node; then
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -1
        apt install -y nodejs 2>&1 | tail -1
        npm install -g pm2 pnpm yarn 2>&1 | tail -1
        sudo -u "${DEPLOY_USER}" XDG_RUNTIME_DIR=/run/user/$(id -u "${DEPLOY_USER}") \
            pm2 startup systemd -u "${DEPLOY_USER}" --hp "/home/${DEPLOY_USER}" 2>/dev/null || true
    fi
    ok "Node.js $(node -v) instalado"

    # ── Python ──
    apt install -y python3-pip python3-venv python3-dev 2>&1 | tail -1
    if ! check_cmd uv; then
        curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null || true
    fi
    ok "Python $(python3 --version 2>&1 | awk '{print $2}') instalado"

    # ── PostgreSQL ──
    if ! check_cmd psql; then
        apt install -y postgresql postgresql-contrib 2>&1 | tail -1
        systemctl enable postgresql --now
        sudo -u postgres psql -c "CREATE USER ${DEPLOY_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
        sudo -u postgres psql -c "CREATE DATABASE homelab OWNER ${DEPLOY_USER};" 2>/dev/null || true
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE homelab TO ${DEPLOY_USER};" 2>/dev/null || true
    fi
    ok "PostgreSQL instalado"

    # ── MariaDB ──
    if ! check_cmd mysql; then
        export DEBIAN_FRONTEND=noninteractive
        apt install -y mariadb-server 2>&1 | tail -1
        systemctl enable mariadb --now
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
        mysql -u root -p"${DB_PASS}" -e "
            CREATE USER IF NOT EXISTS '${DEPLOY_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
            CREATE DATABASE IF NOT EXISTS homelab;
            GRANT ALL ON homelab.* TO '${DEPLOY_USER}'@'localhost';
            FLUSH PRIVILEGES;
        " 2>/dev/null || true
    fi
    ok "MariaDB instalado"

    # ── Redis ──
    if ! check_cmd redis-server; then
        apt install -y redis-server 2>&1 | tail -1
        sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
        systemctl enable redis-server --now
    fi
    ok "Redis instalado"

    ok "Stack de produção completa"
}

# ─────────────────────────────────────────────
#  9️⃣  NGINX
# ─────────────────────────────────────────────
setup_nginx() {
    step "9/12 — NGINX (PROXY REVERSO)"

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > /etc/nginx/nginx.conf << 'NGXEOF'
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml+rss text/javascript;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 100M;

    include /etc/nginx/sites-enabled/*.conf;
}
NGXEOF

    # Default page
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html><head><title>Homelab</title>
<style>body{font-family:system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#0a0a0a;color:#fff}
.box{text-align:center;padding:40px;border:1px solid #333;border-radius:12px}
h1{margin:0 0 10px}p{color:#888;margin:0}</style></head>
<body><div class="box"><h1>🚀 Homelab</h1><p>Servidor operacional</p></div></body></html>
HTMLEOF

    nginx -t 2>&1 && systemctl reload nginx
    ok "Nginx configurado"
}

# ─────────────────────────────────────────────
#  🔟  CLOUDFLARE TUNNEL
# ─────────────────────────────────────────────
setup_tunnel() {
    step "10/12 — CLOUDFLARE TUNNEL"

    # Instalar cloudflared
    if ! check_cmd cloudflared; then
        local cf_url
        cf_url=$(curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
            | jq -r '.assets[] | select(.name == "cloudflared-linux-amd64.deb") | .browser_download_url')
        curl -fsSL "$cf_url" -o /tmp/cloudflared.deb
        apt install -y /tmp/cloudflared.deb 2>&1 | tail -1
        rm -f /tmp/cloudflared.deb
    fi
    ok "cloudflared instalado"

    # Verificar se já está autenticado
    if [ ! -f /root/.cloudflared/cert.pem ]; then
        echo ""
        echo -e "${BD}${Y}══════════════════════════════════════════════════${W}"
        echo -e "${BD}${Y}  CLOUDFLARE LOGIN NECESSÁRIO${W}"
        echo -e "${BD}${Y}══════════════════════════════════════════════════${W}"
        echo -e "${DIM}Vai abrir uma URL no terminal. Copie, abra no navegador,${W}"
        echo -e "${DIM}autorize o domínio ${B}${DOMAIN}${DIM}, e volte aqui.${W}"
        echo ""
        confirm "Pronto para autenticar?" || {
            warn "Pulando tunnel — configure depois com: cloudflared tunnel login"
            return 0
        }
        cloudflared tunnel login
    else
        info "Já autenticado no Cloudflare"
    fi

    # Criar tunnel
    local tunnel_id=""
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
        info "Tunnel '${TUNNEL_NAME}' já existe (ID: ${tunnel_id})"
    else
        cloudflared tunnel create "$TUNNEL_NAME" 2>&1
        tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
        ok "Tunnel criado (ID: ${tunnel_id})"
    fi

    # Configuração
    mkdir -p /root/.cloudflared
    cat > /root/.cloudflared/config.yml << CFEOF
tunnel: ${tunnel_id}
credentials-file: /root/.cloudflared/${tunnel_id}.json

ingress:
  - hostname: cockpit.${DOMAIN}
    service: http://127.0.0.1:9090

  - hostname: files.${DOMAIN}
    service: http://127.0.0.1:8088

  - hostname: code.${DOMAIN}
    service: http://127.0.0.1:8443

  - hostname: "*.app.${DOMAIN}"
    service: http://127.0.0.1:80

  - service: http_status:404
CFEOF

    # DNS routes
    cloudflared tunnel route dns "$TUNNEL_NAME" "cockpit.${DOMAIN}" 2>/dev/null || true
    cloudflared tunnel route dns "$TUNNEL_NAME" "files.${DOMAIN}" 2>/dev/null || true
    cloudflared tunnel route dns "$TUNNEL_NAME" "code.${DOMAIN}" 2>/dev/null || true

    # Instalar como serviço
    cloudflared service install 2>&1
    systemctl enable cloudflared --now

    sleep 3
    if systemctl is-active cloudflared &>/dev/null; then
        ok "Cloudflare Tunnel ativo"
    else
        warn "Tunnel pode não ter conectado — verifique: journalctl -u cloudflared"
    fi

    # Aviso sobre wildcard DNS
    echo ""
    echo -e "${Y}⚠️  DNS MANUAL NECESSÁRIO:${W}"
    echo -e "${DIM}No painel do Cloudflare, crie:${W}"
    echo -e "  Tipo: ${B}CNAME${W}"
    echo -e "  Nome: ${B}*.app${W}"
    echo -e "  Alvo: ${B}${tunnel_id}.cfargotunnel.com${W}"
    echo -e "  Proxy: ${G}Ativado (laranja)${W}"
    echo ""
}

# ─────────────────────────────────────────────
#  1️⃣1️⃣  SCRIPTS + ESTRUTURA
# ─────────────────────────────────────────────
setup_scripts() {
    step "11/12 — SCRIPTS E ESTRUTURA DE DIRETÓRIOS"

    # Diretórios
    mkdir -p "${APPS_DIR}"/{static,php,node,python}
    mkdir -p "${SCRIPT_DIR}" "${BACKUP_DIR}" "${LOGS_DIR}"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}"

    # ── Deploy Script ──
    cat > "${SCRIPT_DIR}/deploy.sh" << 'DEPLOYEOF'
#!/bin/bash
set -e

APPS_DIR="/home/DEPLOY_USER_PLACEHOLDER/apps"
NGINX_DIR="/etc/nginx/sites-available"
NGINX_EN="/etc/nginx/sites-enabled"
LOG_DIR="/home/DEPLOY_USER_PLACEHOLDER/logs"
DOMAIN="DOMAIN_PLACEHOLDER"

ACTION="${1}"; TYPE="${2}"; NAME="${3}"; PORT="${4:-0}"

check_root() { [ "$EUID" -ne 0 ] && echo "❌ Use sudo" && exit 1; }

create_app() {
    local type="$1" name="$2" port="$3"
    local app_dir="${APPS_DIR}/${type}/${name}"
    local subdomain="${name}.${DOMAIN}"

    echo "🚀 Criando: ${name} (${type}) — ${subdomain}"
    mkdir -p "${app_dir}" "${LOG_DIR}/${name}"
    chown -R DEPLOY_USER_PLACEHOLDER:DEPLOY_USER_PLACEHOLDER "${app_dir}" "${LOG_DIR}/${name}"

    case "$type" in
        static)
            cat > "${NGINX_DIR}/${name}.conf" << NGX
server {
    listen 80;
    server_name ${subdomain};
    root ${app_dir};
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    access_log ${LOG_DIR}/${name}/access.log;
    error_log ${LOG_DIR}/${name}/error.log;
}
NGX
            echo "<h1>${name} — Ready</h1>" > "${app_dir}/index.html"
            ;;
        php)
            mkdir -p "${app_dir}/public"
            cat > "${NGINX_DIR}/${name}.conf" << NGX
server {
    listen 80;
    server_name ${subdomain};
    root ${app_dir}/public;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-DEPLOY_USER_PLACEHOLDER.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht { deny all; }
    access_log ${LOG_DIR}/${name}/access.log;
    error_log ${LOG_DIR}/${name}/error.log;
}
NGX
            echo "<?php echo '${name} — PHP Ready'; ?>" > "${app_dir}/public/index.php"
            ;;
        node)
            cat > "${NGINX_DIR}/${name}.conf" << NGX
server {
    listen 80;
    server_name ${subdomain};
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
    access_log ${LOG_DIR}/${name}/access.log;
    error_log ${LOG_DIR}/${name}/error.log;
}
NGX
            mkdir -p "${app_dir}/src"
            cat > "${app_dir}/ecosystem.config.js" << PM2
module.exports = {
  apps: [{
    name: "${name}",
    script: "src/index.js",
    cwd: "${app_dir}",
    instances: 1,
    autorestart: true,
    max_memory_restart: '256M',
    env: { NODE_ENV: "production", PORT: ${port} }
  }]
}
PM2
            echo "const http = require('http'); const s = http.createServer((q,r) => { r.writeHead(200); r.end('${name} OK'); }); s.listen(${port}, () => console.log('${name} :${port}'));" > "${app_dir}/src/index.js"
            ;;
        python)
            cat > "${NGINX_DIR}/${name}.conf" << NGX
server {
    listen 80;
    server_name ${subdomain};
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    access_log ${LOG_DIR}/${name}/access.log;
    error_log ${LOG_DIR}/${name}/error.log;
}
NGX
            cat > "${app_dir}/main.py" << PY
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type','text/html')
        self.end_headers()
        self.wfile.write(b'${name} — Python Ready')
HTTPServer(('127.0.0.1', ${port}), H).serve_forever()
PY
            ;;
        *) echo "❌ Tipo inválido: static, php, node, python"; exit 1 ;;
    esac

    cloudflared tunnel route dns homelab "${subdomain}" 2>/dev/null || true
    ln -sf "${NGINX_DIR}/${name}.conf" "${NGINX_EN}/${name}.conf"
    nginx -t && systemctl reload nginx
    chown -R DEPLOY_USER_PLACEHOLDER:DEPLOY_USER_PLACEHOLDER "${app_dir}"
    echo "✅ ${name} → https://${subdomain}"
    [ "$type" = "node" ] && echo "   ⚡ cd ${app_dir} && pm2 start ecosystem.config.js"
    [ "$type" = "python" ] && echo "   🐍 cd ${app_dir} && python3 main.py &"
}

delete_app() {
    local name="$1"
    echo "🗑️ Removendo: ${name}"
    sudo -u DEPLOY_USER_PLACEHOLDER pm2 delete "${name}" 2>/dev/null || true
    rm -f "${NGINX_EN}/${name}.conf" "${NGINX_DIR}/${name}.conf"
    nginx -t && systemctl reload nginx
    echo "⚠️ Remova o DNS em https://dash.cloudflare.com"
    echo "✅ '${name}' removido (arquivos mantidos)"
}

list_apps() {
    echo "📦 Apps ativas:"
    for c in "${NGINX_EN}"/*.conf; do
        [ -f "$c" ] || continue
        local n=$(basename "$c" .conf)
        local d=$(grep server_name "$c" | head -1 | awk '{print $2}' | tr -d ';')
        echo "  • ${n} → ${d}"
    done
}

case "$ACTION" in
    create)  check_root; create_app "$TYPE" "$NAME" "$PORT" ;;
    delete)  check_root; delete_app "$TYPE" ;;
    list)    list_apps ;;
    *) echo "Uso: sudo $0 {create|delete|list}"; echo "  sudo $0 create {static|php|node|python} nome [porta]"; echo "  sudo $0 delete nome"; echo "  $0 list"; exit 1 ;;
esac
DEPLOYEOF

    # Substituir placeholders
    sed -i "s|DEPLOY_USER_PLACEHOLDER|${DEPLOY_USER}|g" "${SCRIPT_DIR}/deploy.sh"
    sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "${SCRIPT_DIR}/deploy.sh"
    chmod +x "${SCRIPT_DIR}/deploy.sh"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${SCRIPT_DIR}/deploy.sh"

    # ── Status Script ──
    cat > "${SCRIPT_DIR}/status.sh" << 'SEOF'
#!/bin/bash
echo "═══════════════════════════════════════"
echo "  HOMELAB STATUS — $(date)"
echo "═══════════════════════════════════════"
echo ""
echo "🔧 Kernel: $(uname -r) | Uptime: $(uptime -p)"
echo "💾 Disco:"; df -h / | tail -1 | awk '{printf "  %s/%s (%s)\n", $3, $2, $5}'
echo "🧠 RAM:"; free -h | awk '/Mem:/{printf "  %s/%s\n", $3, $2}'
echo "🌐 IP: $(curl -s ifconfig.me 2>/dev/null || echo 'N/A')"
echo ""
echo "⚡ Serviços:"
for s in cloudflared cockpit filebrowser "code-server@DEPLOY_USER_PH" php*-fpm nginx redis postgresql mariadb; do
    st=$(systemctl is-active "$s" 2>/dev/null || echo "off")
    [ "$st" = "active" ] && echo "  ✅ $s" || echo "  ❌ $s"
done
echo ""
echo "📦 Apps:"; sudo "${0%/*}/deploy.sh" list 2>/dev/null
SEOF
    sed -i "s|DEPLOY_USER_PH|${DEPLOY_USER}|g" "${SCRIPT_DIR}/status.sh"
    chmod +x "${SCRIPT_DIR}/status.sh"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${SCRIPT_DIR}/status.sh"

    # ── Backup Script ──
    cat > "${SCRIPT_DIR}/backup.sh" << 'BKEOF'
#!/bin/bash
set -e
BK="/home/DEPLOY_USER_PH/backups"
DT=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BK"
echo "📦 Backup $DT..."
pg_dump -U DEPLOY_USER_PH homelab 2>/dev/null | gzip > "$BK/pg_${DT}.sql.gz" || true
mysqldump -u root -p"DB_PASS_PH" --all-databases 2>/dev/null | gzip > "$BK/mysql_${DT}.sql.gz" || true
tar -czf "$BK/apps_${DT}.tar.gz" -C /home/DEPLOY_USER_PH/apps . 2>/dev/null || true
tar -czf "$BK/configs_${DT}.tar.gz" /etc/nginx/sites-* /etc/php/ /home/DEPLOY_USER_PH/scripts/ /root/.cloudflared/ 2>/dev/null || true
find "$BK" -name "*.gz" -mtime +7 -delete
echo "✅ Backup pronto: $(ls -lh "$BK"/*_${DT}* 2>/dev/null | wc -l) arquivos"
BKEOF
    sed -i "s|DEPLOY_USER_PH|${DEPLOY_USER}|g" "${SCRIPT_DIR}/backup.sh"
    sed -i "s|DB_PASS_PH|${DB_PASS}|g" "${SCRIPT_DIR}/backup.sh"
    chmod +x "${SCRIPT_DIR}/backup.sh"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${SCRIPT_DIR}/backup.sh"

    # Crontab de backup
    (crontab -l 2>/dev/null | grep -v backup.sh; echo "0 3 * * * ${SCRIPT_DIR}/backup.sh >> ${LOGS_DIR}/backup.log 2>&1") | crontab -

    ok "Scripts e estrutura criados"
}

# ─────────────────────────────────────────────
#  1️⃣2️⃣  RESUMO FINAL
# ─────────────────────────────────────────────
print_summary() {
    step "12/12 — INSTALAÇÃO CONCLUÍDA"

    # Salvar credenciais
    cat > "/home/${DEPLOY_USER}/CREDENCIAIS.txt" << CREDEOF
╔══════════════════════════════════════════════════════════╗
║           HOMELAB — CREDENCIAIS GERADAS                 ║
║           ⚠️  APAGUE ESTE ARQUIVO APÓS SALVAR           ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║  Domínio:        ${DOMAIN}                                ║
║  Usuário:        ${DEPLOY_USER}                           ║
║  Senha SO:       ${DEPLOY_PASS}                           ║
║                                                          ║
║  Cockpit:        https://cockpit.${DOMAIN}                ║
║  Senha:          ${COCKPIT_PASS}                          ║
║  Login:          ${DEPLOY_USER}                           ║
║                                                          ║
║  FileBrowser:    https://files.${DOMAIN}                  ║
║  Login:          admin                                   ║
║  Senha:          ${FILEBROWSER_PASS}                      ║
║                                                          ║
║  Code-Server:    https://code.${DOMAIN}                   ║
║  Senha:          ${CODESERVER_PASS}                       ║
║                                                          ║
║  PostgreSQL:     localhost:5432                           ║
║  MariaDB:        localhost:3306                           ║
║  Redis:          localhost:6379                           ║
║  DB User:        ${DEPLOY_USER}                           ║
║  DB Pass:        ${DB_PASS}                               ║
║  DB Name:        homelab                                  ║
║                                                          ║
║  Apps:           https://nome.app.${DOMAIN}               ║
║                                                          ║
║  Comandos úteis:                                         ║
║    sudo ~/scripts/deploy.sh create node api 3000         ║
║    sudo ~/scripts/deploy.sh create php blog              ║
║    sudo ~/scripts/deploy.sh create static site           ║
║    sudo ~/scripts/deploy.sh delete nome                  ║
║    ~/scripts/deploy.sh list                              ║
║    ~/scripts/status.sh                                   ║
║    ~/scripts/backup.sh                                   ║
║                                                          ║
║  ⚠️  DNS MANUAL:                                         ║
║    CNAME  *.app.${DOMAIN}  →  TUNNEL_ID.cfargotunnel.com ║
║    (Proxy: Ativado / Laranja)                             ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
CREDEOF
    chmod 600 "/home/${DEPLOY_USER}/CREDENCIAIS.txt"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/CREDENCIAIS.txt"

    # Imprimir no terminal
    cat "/home/${DEPLOY_USER}/CREDENCIAIS.txt"

    echo ""
    warn "🔴 SALVE AS CREDENCIAIS ACIMA — este arquivo será apagado no reboot"
    warn "🔴 Adicione o DNS wildcard *.app no Cloudflare ANTES de usar"

    # Auto-delete credenciais no reboot
    local systemd_path="/etc/systemd/system/cleanup-creds.service"
    cat > "$systemd_path" << CLEOF
[Unit]
Description=Remove credenciais file
DefaultDependencies=no
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/rm -f /home/${DEPLOY_USER}/CREDENCIAIS.txt

[Install]
WantedBy=local-fs.target
CLEOF
    systemctl daemon-reload
    systemctl enable cleanup-creds.service
}

# ═══════════════════════════════════════════════════════════
#  🚀 EXECUÇÃO PRINCIPAL
# ═══════════════════════════════════════════════════════════
main() {
    echo -e "${BD}${C}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║     🏠 HOMELAB DEBIAN 13 — AUTO SETUP    ║"
    echo "  ║     Domínio: ${DOMAIN}$(printf '%*s' $((21 - ${#DOMAIN})) '')║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${W}"
    echo -e "${DIM}Log: ${LOG_FILE}${W}"
    echo ""

    preflight
    sys_update
    install_basics
    setup_user
    setup_security
    install_cockpit
    install_filebrowser
    install_codeserver
    install_stack
    setup_nginx
    setup_tunnel
    setup_scripts
    print_summary

    echo -e "\n${G}${BD}════════════════════════════════════════${W}"
    echo -e "${G}${BD}  ✅ HOMELAB PRONTO${W}"
    echo -e "${G}${BD}════════════════════════════════════════${W}\n"
}

main "$@"
