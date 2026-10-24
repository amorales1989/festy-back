# Festy en Coolify

Recurso **Docker Compose** desde el repo público `festy-back`, rama `main`, archivo `/docker-compose.coolify.yml`.

| Servicio | Qué hace |
|---|---|
| `db` | PostgreSQL de Supabase (pg_cron, roles). Datos en el volumen `festy-db-datos`. Sin puertos publicados. |
| `auth` | GoTrue: cuentas, login, recuperación de contraseña. |
| `migrador` | Aplica las migraciones pendientes en cada despliegue y termina (código 0). |
| `api` | API de Festy (Node, solo stored procedures). |
| `gateway` | Caddy interno: `/api` → api, `/auth/v1` → auth. Es el único servicio con dominio (`https://<dominio>:8000` en Coolify). |

Variables (pestaña *Environment Variables*): `POSTGRES_PASSWORD`, `JWT_SECRET`, `URL_PUBLICA_API`, `URL_FRONT` y opcionales `SMTP_*`, `AUTOCONFIRMAR_EMAIL`, `DESACTIVAR_REGISTRO`, `FIREBASE_SERVICE_ACCOUNT`.
`POSTGRES_PASSWORD` y `JWT_SECRET` no se cambian después del primer despliegue: la contraseña queda grabada en la base y el secreto firma las sesiones y la clave pública del front.

Para Vercel: `VITE_AUTH_URL=<URL_PUBLICA_API>`, `VITE_API_URL=<URL_PUBLICA_API>/api`, `VITE_AUTH_KEY=<ANON_KEY>` (JWT HS256 con rol `anon` firmado con `JWT_SECRET`; `scripts/generar-secretos.sh` lo calcula).

Respaldos: la pestaña de la base en Coolify no aplica (es un compose); usar `docker exec <contenedor-db> pg_dump -U postgres -Fc postgres > respaldo.dump` desde el VPS o programarlo.
