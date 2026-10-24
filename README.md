# Festy · Backend

API de Festy y su base de datos. El front (repo `festy`, desplegado en Vercel) solo habla con esta API; la base vive en el VPS.

```
Navegador / app Android
   │  /auth/v1  ──────────────►  GoTrue (sesiones, contraseñas, emails)
   │  /api  ──► API Node ──► SELECT api.sp_*(…)  ──►  PostgreSQL (RLS, triggers, pg_cron)
```

## Arquitectura

- **Node 22 + Express 5**, capas `rutas → controladores → repositorios` (como back-rubi). `servicios/` solo tiene lo que no es base de datos (push).
- **Todo acceso a datos es por stored procedure**: los repositorios únicamente llaman a `api.sp_<entidad>_<acción>` mediante `ejecutarSp()` ([src/config/db.js](src/config/db.js)). No hay SQL suelto en la API.
- **La seguridad sigue en la base.** Cada pedido abre una transacción, fija `role = authenticated` y los claims del JWT (`request.jwt.claims`) y llama al SP. Los SP son `SECURITY INVOKER`: la RLS, `auth.uid()`, `exigir_permiso()` y el aislamiento entre organizaciones aplican igual que antes. La API se conecta como `authenticator`, que no puede hacer nada por sí mismo.
- **Autenticación**: GoTrue (de Supabase) emite los tokens; la API los valida con `jose` (HS256 con `JWT_SECRET` en el VPS, o JWKS con la CLI local). El cliente nunca elige su rol de base.
- **Errores**: el cuerpo es `{ code, message, details, hint }` (igual que PostgREST, así el front los traduce sin cambios). SQLSTATE → HTTP: `42501`→403, `P0002`→404, `23P01`/`23505`/`23503`→409, `P0001`/`23514`/`22xxx`→400. Los 500 no exponen detalles.
- **Tareas programadas**: las de negocio (vencer tentativas, recordatorios, purgas) siguen en `pg_cron`. La API solo envía las notificaciones push (cada minuto) con Firebase Cloud Messaging.
- **PostgREST no se publica**: el único camino a los datos es la API.

### Convenciones de los SP
- Esquema `api`, nombre `sp_<entidad>_<acción>`, `set search_path = ''`, devuelven `jsonb` con la forma que usa el front.
- Errores con SQLSTATE válidos y mensaje en español (`raise exception '…' using errcode = 'P0002'`).
- `api.sp_eliminar(entidad, id)` y `api.sp_activar(entidad, id, activo)` tienen una **lista blanca** de tablas; la RLS decide si el usuario puede.
- Privilegios: `execute` solo para `authenticated`; `anon` únicamente `sp_invitacion_ver`; `service_role` únicamente los SP de push.
- Migración: [supabase/migrations/20261024001100_api_sp.sql](supabase/migrations/20261024001100_api_sp.sql). Las reglas de negocio previas (`guardar_reserva`, `registrar_pago`, etc.) se reutilizan: los SP las envuelven.

## Estructura

```
src/
  index.js               arranque, apagado ordenado, tareas programadas
  app.js                 Express: CORS, JSON, rutas, errores
  config/                entorno y pool de PostgreSQL (ejecutarSp)
  middlewares/           autenticación (JWT de GoTrue) y manejo de errores
  rutas/                 sesionRutas, organizacionRutas (/organizaciones/:org/…), recursoRutas (/reservas/:id/…)
  controladores/         leen req, llaman al repositorio, responden
  repositorios/          una función por SP
  servicios/             push (FCM) y tareas programadas
supabase/
  migrations/            esquema, RLS, triggers, reglas de negocio y capa api.sp_*
  tests/                 pgTAP (197 pruebas)
scripts/                 demo.sh (cuenta demo), prueba_concurrencia.sh
tests/                   pruebas de punta a punta de la API (node:test)
despliegue/              docker-compose del VPS, Caddy, scripts de migración/respaldo
```

## Desarrollo local

Requisitos: Node 22+, Docker, Supabase CLI.

```bash
npm install
supabase start                 # Auth 64321 · DB 64322 · Studio 64323 · Mailpit 64324
cp .env.example .env           # ya apunta al Supabase local
npm run dev                    # API en http://localhost:4000
npm run demo                   # cuenta demo@festy.local / demo1234 con datos ficticios
```

En el front: `VITE_API_URL=http://127.0.0.1:4000/api` (ya está en `.env.local`).

## Pruebas

```bash
npm run test:db           # pgTAP: aislamiento, permisos, superposición, cobros, garantías, caja, proveedores, página pública (197)
npm test                  # API de punta a punta: auth, flujo, conflictos 409, garantías, caja, proveedores, página pública, aislamiento (12)
npm run test:concurrencia # dos transacciones reales compitiendo por el mismo espacio
```
Los e2e de Playwright del front (`npx playwright test` en `festy`) recorren la app completa contra esta API.

## Endpoints

Todos bajo `/api`, con `Authorization: Bearer <token de GoTrue>`, salvo `GET /api/invitaciones/:token` y `/api/publico/*` (página pública del salón).
`:org` es el id de la organización. Respuestas `204` = sin cuerpo.

| Área | Endpoints |
|---|---|
| Sesión | `GET /perfil` · `PUT /perfil/organizacion` · `GET/POST /organizaciones` · `GET /notificaciones` · `POST /notificaciones/leer` · `POST /dispositivos` · `DELETE /dispositivos/:token` · `GET /invitaciones/:token` (pública) · `POST /invitaciones/:token/aceptar` |
| Organización | `GET /organizaciones/:org/contexto` (org, permisos, rol, plan y sedes) · `PATCH /organizaciones/:org` · `POST/DELETE …/baja` · `GET …/checklist` · `POST/DELETE …/ejemplos` · `GET …/panel` · `GET …/buscar?q=` · `GET …/miembros` · `GET …/exportar` · `POST …/importar/clientes` · `POST …/importar/reservas` |
| Sedes | `POST/PUT …/salones[/:id]` · `POST/PUT …/sucursales[/:id]` · `POST/PUT …/espacios[/:id]` (`{ datos, horarios }`) · `GET /espacios/:id/horarios` · `GET/POST/PUT …/recursos` · `GET/POST …/feriados` |
| Clientes | `GET …/clientes?q&limite&desplazamiento` · `GET …/clientes/buscar?q` · `POST/PUT …/clientes[/:id]` · `GET /clientes/:id` (con eventos y presupuestos) |
| Reservas | `GET …/reservas?estado&contrato&desde&hasta&sucursal&texto&limite&desplazamiento` · `POST/PUT …/reservas[/:id]` (`{ datos, espacios }`) · `GET /reservas/:id` · `GET /reservas/:id/ficha` · `PATCH /reservas/:id/estado` · `PATCH /reservas/:id/contrato` · `POST /reservas/:id/items` · `POST …/disponibilidad` · `GET …/agenda` · `POST …/bloqueos` |
| Cobros | `POST /reservas/:id/pagos` · `PATCH /pagos/:id/anular` · `GET /pagos/:id/comprobante` · `GET …/cobros?desde&hasta` · `GET …/cuotas?vista&hoy` · `POST/PUT …/reservas/:id/cuotas` |
| Garantías | `GET …/garantias` · `PUT/DELETE /reservas/:id/garantia` · `POST /reservas/:id/garantia/cobro` · `POST /reservas/:id/garantia/devolucion` |
| Caja | `GET/POST/PUT …/cuentas` · `GET …/caja?desde&hasta` (saldos por cuenta y movimientos) · `POST …/transferencias` |
| Proveedores y rentabilidad | `GET/POST/PUT …/proveedores` · `POST/PUT …/costos` · `GET /reservas/:id/costos` · `POST /reservas/:id/costos/catalogo` · `POST /costos/:id/pagos` (registra el gasto) · `GET …/rentabilidad?desde&hasta` |
| Página pública | `PUT …/pagina` (configuración) · `GET …/pedidos-web` (pedidos sin atender) · `POST /reservas/:id/pedido-web/atendido` · sin sesión y con límite por IP: `GET /publico/:slug` · `GET /publico/:slug/ocupacion?desde&hasta` · `POST /publico/:slug/pedidos` |
| Gastos y tareas | `GET/POST/PUT …/gastos` · `GET/POST/PUT …/tareas` · `PATCH /tareas/:id/estado` |
| Ventas | `GET/POST/PUT …/servicios` · `GET/POST/PUT …/presupuestos` · `GET /presupuestos/:id` · `POST /presupuestos/:id/aceptar` · `GET/POST/PUT …/entrevistas` · `GET /entrevistas/:id` |
| Equipo | `GET …/roles` · `GET …/roles/matriz` · `PUT …/roles/permisos` · `GET/POST …/invitaciones` · `DELETE /invitaciones/:id` · `PATCH /membresias/:id` · `GET …/auditoria` |
| Genéricos | `DELETE /registros/:entidad/:id` · `PATCH /registros/:entidad/:id/activo` |

## Despliegue en el VPS

Requisitos del VPS: Docker con Compose, un dominio para la API (ej. `api.tudominio.com`) apuntando a la IP del VPS, puertos 80/443 libres (si hay Traefik/Easypanel, ver el comentario del servicio `gateway`).

```bash
# 1. Subir este repo al VPS (git clone o rsync) y entrar a despliegue/
cd despliegue
./scripts/generar-secretos.sh api.tudominio.com https://tu-front.vercel.app   # crea .env (una sola vez)
#    Guardá una copia de .env fuera del VPS. Revisá SMTP_* para los emails de confirmación y recuperación.

# 2. Levantar base, autenticación, API y Caddy (HTTPS automático)
docker compose up -d --build db auth api gateway

# 3. Crear el esquema (aplica supabase/migrations en orden, con privilegios iguales a los probados)
./scripts/migrar.sh
./scripts/probar-db.sh          # opcional: corre las 160 pruebas pgTAP contra la base del VPS (no deja datos)

# 4. Verificar
curl https://api.tudominio.com/salud     # {"estado":"ok"}
```

En **Vercel** (proyecto `festy`), variables de entorno que imprime `generar-secretos.sh`:
`VITE_AUTH_URL=https://api.tudominio.com`, `VITE_AUTH_KEY=<ANON_KEY>`, `VITE_API_URL=https://api.tudominio.com/api`.
`ORIGENES_PERMITIDOS` de la API toma `URL_FRONT` del `.env`; si usás un dominio propio en Vercel, cambiá `URL_FRONT` y `URLS_REDIRECCION_EXTRA` y reiniciá `api` y `auth`.

Operación:
- Actualizar: `git pull && docker compose up -d --build api && ./scripts/migrar.sh`
- Respaldo: `./scripts/respaldo.sh` (pg_dump comprimido en `despliegue/respaldos/`, con retención). Programalo en el cron del VPS.
- Studio (panel de la base): `docker compose up -d meta studio` y luego `ssh -L 3000:127.0.0.1:3000 usuario@vps` → http://localhost:3000.
- Postgres solo escucha en `127.0.0.1`; para conectarte: `ssh -L 5432:127.0.0.1:5432 usuario@vps`.
- Push en Android: pegar el JSON de la cuenta de servicio de Firebase (en una línea) en `FIREBASE_SERVICE_ACCOUNT` y `docker compose up -d api`.

Verificado localmente con este mismo compose (PostgreSQL 17): migraciones, 160 pruebas pgTAP, token HS256 de GoTrue → API → SP, `/rest/v1` no expuesto, CORS restringido al front y Postgres solo en 127.0.0.1. **No** se probó todavía en el VPS real ni con un dominio/certificado real.
