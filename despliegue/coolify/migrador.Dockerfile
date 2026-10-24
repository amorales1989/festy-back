# Aplica las migraciones pendientes en cada despliegue y termina.
# Usa la misma imagen base que la base de datos (trae psql; capas compartidas).
FROM supabase/postgres:17.6.1.136
COPY supabase/migrations /app/supabase/migrations
COPY despliegue/scripts/migrar.sh /app/despliegue/scripts/migrar.sh
ENTRYPOINT ["bash", "/app/despliegue/scripts/migrar.sh"]
