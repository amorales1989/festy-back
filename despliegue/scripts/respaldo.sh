#!/usr/bin/env bash
# Respaldo comprimido de la base. Pensado para cron diario, ej.:
#   30 3 * * * /opt/festy/Festy-back/despliegue/scripts/respaldo.sh >> /var/log/festy-respaldo.log 2>&1
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${DIR_RESPALDOS:-./respaldos}"
DIAS="${DIAS_RETENCION:-14}"
mkdir -p "$DIR"
archivo="$DIR/festy-$(date +%Y%m%d-%H%M).dump"
docker exec festy-db pg_dump -U postgres -h localhost -d postgres -Fc --no-owner > "$archivo"
echo "$(date -Iseconds) respaldo: $archivo ($(du -h "$archivo" | cut -f1))"
find "$DIR" -name 'festy-*.dump' -mtime +"$DIAS" -delete
# Restaurar: docker exec -i festy-db pg_restore -U postgres -h localhost -d postgres --clean --if-exists < archivo.dump
