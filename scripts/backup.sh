#!/usr/bin/env bash
#
# Backup lógico do Postgres (pg_dumpall) + arquivos do Storage.
#
# Uso (na VPS, como root):
#   ./scripts/backup.sh                        # grava em /var/backups/supabase
#   ./scripts/backup.sh --dest /mnt/backup --keep 14
#
# Cron sugerido (diário às 03:15, horário da VPS):
#   15 3 * * * /opt/datalake-bwa/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
#
# Importante: o backup na mesma VPS não protege contra perda da VPS.
# Copie /var/backups/supabase para fora (rclone/S3/B2) - veja docs/runbook.md.

set -euo pipefail

TARGET_DIR="/docker/supabase"
DEST="/var/backups/supabase"
KEEP=7

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
done

ts="$(date +%Y%m%d-%H%M%S)"
umask 077
mkdir -p "$DEST"
cd "$TARGET_DIR"

echo "[backup] $ts pg_dumpall"
docker compose exec -T db pg_dumpall -U supabase_admin --clean --if-exists \
  | gzip -6 > "$DEST/db-$ts.sql.gz.partial"
mv "$DEST/db-$ts.sql.gz.partial" "$DEST/db-$ts.sql.gz"

if [ -d volumes/storage ] && [ -n "$(ls -A volumes/storage 2>/dev/null)" ]; then
  echo "[backup] $ts storage"
  tar -C volumes -czf "$DEST/storage-$ts.tar.gz" storage
fi

echo "[backup] retenção: removendo arquivos com mais de $KEEP dias"
find "$DEST" -maxdepth 1 -type f \( -name 'db-*.sql.gz' -o -name 'storage-*.tar.gz' \) -mtime +"$KEEP" -delete

ls -lh "$DEST" | tail -n +2
echo "[backup] ok"
