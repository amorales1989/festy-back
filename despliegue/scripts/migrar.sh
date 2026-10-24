#!/usr/bin/env bash
# Aplica las migraciones pendientes de ../supabase/migrations a la base del VPS.
# Registra lo aplicado en supabase_migrations.schema_migrations (la misma tabla
# que usa la CLI de Supabase). Cada migración corre en una transacción.
set -euo pipefail
cd "$(dirname "$0")/.."
CONTENEDOR="${CONTENEDOR_DB:-festy-db}"
if [ -n "${PGHOST:-}" ]; then
  # Modo directo (servicio "migrador" en Coolify): psql por red con PGHOST/PGPASSWORD.
  psql_db() { psql -v ON_ERROR_STOP=1 -U postgres -d postgres -qtA "$@"; }
else
  psql_db() { docker exec -i "$CONTENEDOR" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -h localhost -qtA "$@"; }
fi

# Privilegios por defecto iguales a los de la CLI de Supabase (donde corren las
# pruebas): lo nuevo en public NO queda abierto a anon/authenticated; cada
# migración otorga explícitamente lo que hace falta. La imagen autoalojada, en
# cambio, da todos los privilegios por defecto. Debe correr antes de migrar.
psql_db <<'SQL' >/dev/null
alter default privileges for role postgres in schema public revoke select, insert, update, delete, truncate on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke usage, select on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated, service_role;
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
SQL

aplicadas=0
for archivo in ../supabase/migrations/*.sql; do
  nombre=$(basename "$archivo" .sql)
  version=${nombre%%_*}
  if [ -n "$(psql_db -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")" ]; then
    continue
  fi
  echo "→ $nombre"
  { echo "begin;"; cat "$archivo"; echo;
    echo "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '${nombre#*_}');";
    echo "commit;"; } | psql_db >/dev/null
  aplicadas=$((aplicadas + 1))
done
echo "Migraciones aplicadas: $aplicadas"
