# Base de datos de Festy: PostgreSQL de Supabase (pg_cron, roles de auth) con
# los scripts de inicio incluidos en la imagen (Coolify no necesita montar archivos).
FROM supabase/postgres:17.6.1.136
COPY despliegue/volumes/db/webhooks.sql /docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql
COPY despliegue/volumes/db/roles.sql /docker-entrypoint-initdb.d/init-scripts/99-roles.sql
COPY despliegue/volumes/db/jwt.sql /docker-entrypoint-initdb.d/init-scripts/99-jwt.sql
