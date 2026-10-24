#!/usr/bin/env bash
# Corre las pruebas pgTAP de ../supabase/tests contra la base del contenedor.
# Cada archivo termina en ROLLBACK: no deja datos.
set -euo pipefail
cd "$(dirname "$0")/.."
CONTENEDOR="${CONTENEDOR_DB:-festy-db}"
fallas=0
for t in ../supabase/tests/*.sql; do
  salida=$(docker exec -i "$CONTENEDOR" psql -U postgres -d postgres -h localhost -qtA < "$t" 2>&1 || true)
  total=$(echo "$salida" | grep -cE '^ok [0-9]+' || true)
  malas=$(echo "$salida" | grep -E '^not ok|ERROR' || true)
  if [ -n "$malas" ]; then
    echo "FALLA $(basename "$t")"; echo "$malas" | head -10; fallas=1
  else
    echo "ok    $(basename "$t") ($total pruebas)"
  fi
done
exit $fallas
