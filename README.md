# Dienstplan — Installer

Installationsscript für Dienstplan-Instanzen auf eigener Infrastruktur.

## Systemvoraussetzungen

- Ubuntu 20.04+ oder Debian 11+
- Mindestens 2 GB RAM, 10 GB freier Speicher
- Eine Domain mit DNS-A-Record auf die Server-IP
- Ports 80 + 443 frei (kein anderer Webserver aktiv)

## Erstinstallation

```bash
curl -fsSL https://install.jd-app.de/setup.sh | bash
```

Sicherheits-Tipp — Script vor Ausführung prüfen:
```bash
curl -O https://install.jd-app.de/setup.sh
less setup.sh
bash setup.sh
```

### Non-interaktiv (für automatisiertes Setup)

```bash
bash setup.sh \
  --domain=plan.drk-musterstadt.de \
  --email=admin@drk-musterstadt.de \
  --yes
```

## Update

```bash
cd /opt/dienstplan && ./update.sh
```

Optionen:
- `--dry-run` — zeigt was gemacht würde, ohne Änderungen
- `--no-backup` — überspringt Datenbank-Backup
- `--rollback` — rollback auf vorherige Version

## Deinstallation

```bash
# Container stoppen, Daten behalten:
sudo bash /opt/dienstplan/uninstall.sh

# Komplett löschen inkl. Daten:
sudo bash /opt/dienstplan/uninstall.sh --purge
```

## Troubleshooting

**HTTPS-Zertifikat wird nicht ausgestellt:**
Prüfe ob Port 80 + 443 von außen erreichbar sind und der DNS-Eintrag korrekt ist.

**Container startet nicht:**
```bash
cd /opt/dienstplan && docker compose -f docker-compose.prod.yml logs backend
```

**Datenbank nicht erreichbar:**
```bash
cd /opt/dienstplan && docker compose -f docker-compose.prod.yml logs db
```

**Admin-Passwort vergessen:**
```bash
cd /opt/dienstplan
docker compose -f docker-compose.prod.yml exec backend \
  node dist/scripts/reset-admin-password.js Admin NeuesPasswort123
```
