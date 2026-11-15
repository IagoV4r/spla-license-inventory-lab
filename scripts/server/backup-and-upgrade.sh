#!/usr/bin/env bash
# Safe PostgreSQL major upgrade for the server stack (run from the compose folder, as root).
# 1. Logical backup + validation  2. Stop  3. New volume on the new version  4. Restore  5. Verify
# The old volume is kept as the rollback path; delete it only after the agreed validation period.
set -euo pipefail

backup="backups/ocview-$(date +%Y%m%d-%H%M).dump"
mkdir -p backups

docker compose exec -T db pg_dump -U ocview -d ocview -Fc > "$backup"
docker compose exec -T db pg_restore --list < "$backup" | grep -q 'TABLE' || { echo "Backup not readable: $backup"; exit 1; }
echo "Backup validated: $backup"

echo "Now edit compose.yaml: new image tag AND a new volume name, then press Enter."
read -r

docker compose down          # volumes are kept (never use -v here)
docker compose up -d
until docker compose exec -T db pg_isready -U ocview -d ocview >/dev/null 2>&1; do sleep 2; done

docker compose exec -T db pg_restore -U ocview -d ocview --no-owner < "$backup"
docker compose exec -T db psql -U ocview -d ocview -c 'SHOW server_version;' -c 'SELECT count(*) AS inventory_rows FROM inventory;'
docker volume ls | grep pgdata
