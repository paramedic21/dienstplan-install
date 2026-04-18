#!/usr/bin/env bash
set -euo pipefail
cd /opt/dienstplan

BACKUP_FIRST="true"
for arg in "$@"; do
  case "$arg" in --no-backup) BACKUP_FIRST="false" ;; esac
done

if [[ "$BACKUP_FIRST" == "true" ]]; then
  BACKUP="backup-$(date +%Y%m%d-%H%M%S).sql.gz"
  docker compose -f docker-compose.prod.yml exec -T db \
    sh -c 'mysqldump -u dienstplan -p"$MYSQL_PASSWORD" dienstplan' | gzip > "$BACKUP"
fi

docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
echo "Update abgeschlossen."
