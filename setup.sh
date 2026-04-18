#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

INSTALLER_VERSION="1.0.0"
INSTALL_DIR="/opt/dienstplan"
REPO_RAW="https://install.jd-app.de"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
step()  { echo -e "${CYAN}→${NC} $*"; }

# ── Flags ──────────────────────────────────────────────────────
DOMAIN=""; EMAIL=""; YES_MODE="false"
SMTP_HOST=""; SMTP_PORT="587"; SMTP_USER=""; SMTP_PASS=""; SMTP_FROM=""

for arg in "$@"; do
  case "$arg" in
    --domain=*)   DOMAIN="${arg#*=}" ;;
    --email=*)    EMAIL="${arg#*=}" ;;
    --yes)        YES_MODE="true" ;;
    --smtp-host=*) SMTP_HOST="${arg#*=}" ;;
    --smtp-user=*) SMTP_USER="${arg#*=}" ;;
    --smtp-pass=*) SMTP_PASS="${arg#*=}" ;;
    --smtp-from=*) SMTP_FROM="${arg#*=}" ;;
    *) fail "Unbekannte Option: $arg" ;;
  esac
done

# ── Rollback bei Fehler ──────────────────────────────────────────
INSTALLED=false
rollback() {
  if [[ "$INSTALLED" == "false" ]] && [[ -d "$INSTALL_DIR" ]]; then
    warn "Fehler aufgetreten — räume auf..."
    docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" down --volumes 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    warn "Aufgeräumt. Bitte Fehlerursache beheben und erneut versuchen."
  fi
}
trap 'echo -e "${RED}✗ Fehler in Zeile $LINENO${NC}"; rollback; exit 1' ERR

# ── Root-Check ───────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && fail "Bitte als root ausführen: sudo bash setup.sh"

# ── Prerequisites ────────────────────────────────────────────────
step "Prüfe Systemvoraussetzungen..."

grep -qE "(Ubuntu|Debian)" /etc/os-release 2>/dev/null \
  || fail "Nur Ubuntu 20+ oder Debian 11+ unterstützt."

if command -v free &>/dev/null; then
  RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
else
  RAM_MB=$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)
fi
[[ $RAM_MB -lt 1800 ]] && fail "Mindestens 2 GB RAM erforderlich (gefunden: ${RAM_MB} MB)."

DISK_GB=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
[[ $DISK_GB -lt 10 ]] && fail "Mindestens 10 GB freier Speicher erforderlich (verfügbar: ${DISK_GB} GB)."

for port in 80 443; do
  ss -tuln | grep -q ":$port " \
    && fail "Port $port ist belegt. Bitte zuerst anderen Webserver (nginx/apache) stoppen."
done

info "Systemvoraussetzungen erfüllt (RAM: ${RAM_MB} MB, Disk frei: ${DISK_GB} GB)"

if ! command -v docker &>/dev/null; then
  step "Installiere Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  info "Docker installiert."
fi
docker compose version &>/dev/null || fail "docker-compose-plugin fehlt: apt-get install docker-compose-plugin"

# ── Interaktive Eingaben ─────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "  Dienstplan — Erstinstallation v${INSTALLER_VERSION}"
echo "══════════════════════════════════════════════════"
echo ""

if [[ -z "$DOMAIN" ]]; then
  read -rp "  Domain (z.B. plan.drk-musterstadt.de): " DOMAIN
fi
[[ -z "$DOMAIN" ]] && fail "Domain darf nicht leer sein."

SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
RESOLVED_IP=$(dig +short "$DOMAIN" A 2>/dev/null | tail -1 || true)
if [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
  warn "DNS: $DOMAIN → $RESOLVED_IP, Server-IP: $SERVER_IP"
  if [[ "$YES_MODE" != "true" ]]; then
    read -rp "  DNS stimmt noch nicht überein. Trotzdem fortfahren? [j/N]: " ans
    [[ "${ans,,}" != "j" ]] && exit 0
  fi
else
  info "DNS-Check: $DOMAIN → $SERVER_IP ✓"
fi

if [[ -z "$EMAIL" ]]; then
  read -rp "  E-Mail für Let's Encrypt (Zertifikat-Benachrichtigungen): " EMAIL
fi
[[ -z "$EMAIL" ]] && fail "E-Mail darf nicht leer sein."

if [[ -z "$SMTP_HOST" ]] && [[ "$YES_MODE" != "true" ]]; then
  read -rp "  SMTP einrichten? (für Passwort-Reset-Mails) [j/N]: " setup_smtp
  if [[ "${setup_smtp,,}" == "j" ]]; then
    read -rp "  SMTP-Host: " SMTP_HOST
    read -rp "  SMTP-Port [587]: " smtp_port_in
    SMTP_PORT="${smtp_port_in:-587}"
    read -rp "  SMTP-Benutzer: " SMTP_USER
    read -rsp "  SMTP-Passwort: " SMTP_PASS; echo ""
    read -rp "  Absender-Adresse: " SMTP_FROM
  fi
fi

# ── Secret-Generierung ────────────────────────────────────────────
step "Generiere Secrets..."
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
MYSQL_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32)
JWT_SECRET=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 64)
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
info "Secrets generiert."

# ── Verzeichnis + Dateien ─────────────────────────────────────────
step "Richte Installationsverzeichnis ein..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

curl -fsSL "$REPO_RAW/docker-compose.prod.yml" -o docker-compose.prod.yml
curl -fsSL "$REPO_RAW/Caddyfile.tpl" -o Caddyfile.tpl
curl -fsSL "$REPO_RAW/.env.tpl" -o .env.tpl

render() {
  sed \
    -e "s|{{DOMAIN}}|$DOMAIN|g" \
    -e "s|{{EMAIL}}|$EMAIL|g" \
    -e "s|{{MYSQL_ROOT_PASSWORD}}|$MYSQL_ROOT_PASSWORD|g" \
    -e "s|{{MYSQL_PASSWORD}}|$MYSQL_PASSWORD|g" \
    -e "s|{{JWT_SECRET}}|$JWT_SECRET|g" \
    -e "s|{{SMTP_HOST}}|$SMTP_HOST|g" \
    -e "s|{{SMTP_PORT}}|$SMTP_PORT|g" \
    -e "s|{{SMTP_USER}}|$SMTP_USER|g" \
    -e "s|{{SMTP_PASS}}|$SMTP_PASS|g" \
    -e "s|{{SMTP_FROM}}|$SMTP_FROM|g" \
    "$1"
}

render Caddyfile.tpl > Caddyfile
render .env.tpl > .env
rm Caddyfile.tpl .env.tpl
chmod 600 .env

step "Generiere Datenbank-Verschlüsselungsschlüssel..."
mkdir -p db/encryption db/conf.d
openssl rand -base64 32 > db/encryption/keyfile.password
KEY=$(openssl rand -hex 32)
echo "1;$KEY" > db/encryption/keys.txt
openssl enc -aes-256-cbc -md sha1 \
  -pass file:db/encryption/keyfile.password \
  -in db/encryption/keys.txt \
  -out db/encryption/keys.enc
rm db/encryption/keys.txt
chmod 600 db/encryption/keyfile.password db/encryption/keys.enc

cat > db/conf.d/encryption.cnf <<'CNF'
[mariadb]
plugin_load_add = file_key_management
file_key_management_filename = /etc/mysql/encryption/keys.enc
file_key_management_filekey = FILE:/etc/mysql/encryption/keyfile.password
innodb_encrypt_tables = ON
innodb_encrypt_log = ON
innodb_encryption_threads = 4
CNF

info "Encryption-Keys generiert."

step "Lade Docker-Images (kann einige Minuten dauern)..."
docker compose -f docker-compose.prod.yml pull

step "Starte Container..."
docker compose -f docker-compose.prod.yml up -d

step "Warte auf Datenbank..."
for i in {1..30}; do
  docker compose -f docker-compose.prod.yml exec -T db \
    healthcheck.sh --connect --innodb_initialized 2>/dev/null && break
  sleep 3
done
info "Datenbank bereit."

step "Warte auf Backend..."
for i in {1..40}; do
  docker compose -f docker-compose.prod.yml exec -T backend \
    wget -q --spider http://localhost:4000/api/health 2>/dev/null && break
  sleep 3
done
info "Backend bereit."

step "Lege Admin-Benutzer an..."
docker compose -f docker-compose.prod.yml exec -T backend \
  node dist/scripts/create-admin.js 2>/dev/null || true
docker compose -f docker-compose.prod.yml exec -T backend \
  node dist/scripts/reset-admin-password.js Admin "$ADMIN_PASSWORD"
info "Admin-Benutzer angelegt."

INSTALLED=true

cat > update.sh <<'UPDATEEOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/dienstplan

DRY_RUN="false"; BACKUP_FIRST="true"; ROLLBACK="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN="true" ;;
    --no-backup)     BACKUP_FIRST="false" ;;
    --rollback)      ROLLBACK="true" ;;
  esac
done

if [[ "$ROLLBACK" == "true" ]]; then
  PREV=$(cat .previous-tag 2>/dev/null || echo "")
  [[ -z "$PREV" ]] && echo "Kein vorheriges Image gespeichert." && exit 1
  sed -i "s|:latest|:$PREV|g" docker-compose.prod.yml
  docker compose -f docker-compose.prod.yml up -d
  echo "✓ Rollback auf $PREV abgeschlossen."
  exit 0
fi

if [[ "$BACKUP_FIRST" == "true" ]]; then
  BACKUP="backup-$(date +%Y%m%d-%H%M%S).sql.gz"
  echo "→ Erstelle Datenbank-Backup: $BACKUP"
  docker compose -f docker-compose.prod.yml exec -T db \
    sh -c 'mysqldump -u dienstplan -p"$MYSQL_PASSWORD" dienstplan' | gzip > "$BACKUP"
  echo "✓ Backup gespeichert: $BACKUP"
fi

echo "→ Lade neue Images..."
docker compose -f docker-compose.prod.yml pull

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✓ Dry-run abgeschlossen — keine Änderungen vorgenommen."
  exit 0
fi

echo "→ Starte Container neu..."
docker compose -f docker-compose.prod.yml up -d
echo "✓ Update abgeschlossen."
UPDATEEOF
chmod +x update.sh

step "Richte automatisches Update (Systemd) ein..."
cat > /etc/systemd/system/dienstplan-update.path <<'EOF'
[Unit]
Description=Dienstplan Update Trigger

[Path]
PathExists=/opt/dienstplan/.update-requested

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/dienstplan-update.service <<'EOF'
[Unit]
Description=Dienstplan Auto-Update

[Service]
Type=oneshot
WorkingDirectory=/opt/dienstplan
ExecStart=/opt/dienstplan/update.sh --no-backup
ExecStartPost=/bin/rm -f /opt/dienstplan/.update-requested
StandardOutput=journal
StandardError=journal
EOF

systemctl daemon-reload
systemctl enable --now dienstplan-update.path
info "Automatisches Update eingerichtet."

echo ""
echo "══════════════════════════════════════════════════"
echo -e "${GREEN}  ✓ Installation abgeschlossen!${NC}"
echo "══════════════════════════════════════════════════"
echo ""
echo "  URL    : https://${DOMAIN}"
echo "  Login  : Admin"
echo "  Passwort: ${ADMIN_PASSWORD}"
echo ""
echo "  Testphase: 7 Tage aktiv."
echo "  Lizenz eintragen: Admin-Bereich → Lizenz"
echo ""
echo "  Update: cd ${INSTALL_DIR} && ./update.sh"
echo ""
warn "Passwort jetzt notieren — wird nicht gespeichert!"
warn "DB-Keys sichern: ${INSTALL_DIR}/db/encryption/ (USB + Tresor)"
