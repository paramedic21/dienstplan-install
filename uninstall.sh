#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/dienstplan"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
warn() { echo -e "${YELLOW}!${NC} $*"; }
info() { echo -e "${GREEN}✓${NC} $*"; }

PURGE="false"
[[ "${1:-}" == "--purge" ]] && PURGE="true"

[[ $EUID -ne 0 ]] && echo "Bitte als root ausführen: sudo bash uninstall.sh" && exit 1
[[ ! -d "$INSTALL_DIR" ]] && echo "Dienstplan ist nicht in $INSTALL_DIR installiert." && exit 0

echo -e "${RED}⚠  Dienstplan deinstallieren${NC}"
if [[ "$PURGE" == "true" ]]; then
  echo "   ALLE Daten (Datenbank, Uploads, Backups) werden GELÖSCHT."
else
  echo "   Container werden gestoppt. Daten bleiben erhalten."
fi
echo ""
read -rp "Fortfahren? [j/N]: " ans
[[ "${ans,,}" != "j" ]] && exit 0

cd "$INSTALL_DIR"

if [[ "$PURGE" == "true" ]]; then
  docker compose -f docker-compose.prod.yml down --volumes --remove-orphans 2>/dev/null || true
  cd /
  rm -rf "$INSTALL_DIR"
  info "Dienstplan vollständig entfernt inkl. aller Daten."
else
  docker compose -f docker-compose.prod.yml down --remove-orphans 2>/dev/null || true
  info "Container gestoppt. Daten in $INSTALL_DIR bleiben erhalten."
  echo "  Vollständig löschen: sudo bash uninstall.sh --purge"
fi
