#!/usr/bin/env bash
# Genera despliegue/.env con claves nuevas y aleatorias. Se corre UNA sola vez:
# si se regeneran, las sesiones y la clave pública del front dejan de valer.
#   ./scripts/generar-secretos.sh api.tudominio.com https://tu-front.vercel.app
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ] && [ "${FORZAR:-0}" != "1" ]; then
  echo "Ya existe .env. Para regenerarlo (invalida sesiones y claves): FORZAR=1 $0 …" >&2
  exit 1
fi
DOMINIO="${1:?Uso: $0 <dominio-api> <url-front>   ej: $0 api.festy.com.ar https://festy.vercel.app}"
FRONT="${2:?Falta la URL del front (Vercel)}"
URL_API="https://${DOMINIO}"
[ "$DOMINIO" = "localhost" ] && URL_API="http://localhost:${PUERTO_PRUEBA:-18000}"

aleatorio() { openssl rand -hex "$1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() {  # $1 = rol
  local ahora=$(date +%s)
  local enc=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  local carga=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$1" "$ahora" $((ahora + 10 * 365 * 24 * 3600)) | b64url)
  local firma=$(printf '%s.%s' "$enc" "$carga" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
  printf '%s.%s.%s' "$enc" "$carga" "$firma"
}

POSTGRES_PASSWORD=$(aleatorio 24)
JWT_SECRET=$(aleatorio 32)
ANON_KEY=$(jwt anon)
SERVICE_ROLE_KEY=$(jwt service_role)

umask 077
cat > .env <<ENV
# Generado el $(date -Iseconds). NO subir a git. Guardá una copia en un lugar seguro.

# --- Dominios ---
API_DOMINIO=${DOMINIO}
URL_PUBLICA_API=${URL_API}
URL_FRONT=${FRONT}
URLS_REDIRECCION_EXTRA=${FRONT}/**

# --- Secretos ---
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY=3600
# Clave pública de GoTrue: va en Vercel como VITE_AUTH_KEY
ANON_KEY=${ANON_KEY}
# Clave de administrador: NUNCA en el front
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
PG_META_CRYPTO_KEY=$(aleatorio 32)

# --- Registro y emails ---
# Registro público cerrado: las empresas se crean desde /plataforma (emails de ADMIN_PLATAFORMA)
DESACTIVAR_REGISTRO=true
ADMIN_PLATAFORMA=
# true mientras no haya SMTP: las cuentas se activan sin confirmar el email.
AUTOCONFIRMAR_EMAIL=true
SMTP_REMITENTE=no-responder@${DOMINIO#api.}
SMTP_HOST=
SMTP_PUERTO=587
SMTP_USUARIO=
SMTP_CLAVE=
SMTP_NOMBRE=Festy

# --- Puertos ---
PUERTO_HTTP=80
PUERTO_HTTPS=443
PUERTO_GATEWAY=127.0.0.1:8000
PUERTO_DB_LOCAL=5432
PUERTO_STUDIO_LOCAL=3000

# --- Push (opcional): JSON de la cuenta de servicio de Firebase en UNA línea ---
FIREBASE_SERVICE_ACCOUNT=
ENV
echo "Listo: despliegue/.env"
echo
echo "Para Vercel:"
echo "  VITE_AUTH_URL=${URL_API}"
echo "  VITE_API_URL=${URL_API}/api"
echo "  VITE_AUTH_KEY=${ANON_KEY}"
