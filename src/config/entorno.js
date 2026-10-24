// Configuración leída del entorno. Falla al arrancar si falta algo obligatorio.
const requerida = (nombre) => {
    const valor = process.env[nombre]
    if (!valor) throw new Error(`Falta la variable de entorno ${nombre}`)
    return valor
}

export const entorno = {
    puerto: Number(process.env.PORT || 4000),
    // Conexión como rol `authenticator`: solo puede asumir authenticated/anon/service_role.
    urlBase: requerida('DATABASE_URL'),
    // GoTrue firma los tokens con HS256 (VPS, JWT_SECRET) o con claves asimétricas (Supabase CLI, JWKS).
    jwtSecreto: process.env.JWT_SECRET || '',
    // Claves públicas de GoTrue (tokens ES256/RS256). Por defecto, las de AUTH_URL/auth/v1.
    urlJwks: process.env.AUTH_JWKS_URL || `${requerida('AUTH_URL').replace(/\/$/, '')}/auth/v1/.well-known/jwks.json`,
    jwtEmisor: process.env.JWT_ISSUER || '',
    // Orígenes permitidos para CORS (front en Vercel, app Capacitor, local). Separados por coma.
    origenes: (process.env.ORIGENES_PERMITIDOS || 'http://localhost:5173').split(',').map((o) => o.trim()).filter(Boolean),
    // Push (Firebase Cloud Messaging). Sin esto, la tarea de push no se programa.
    firebaseCuenta: process.env.FIREBASE_SERVICE_ACCOUNT || '',
    tareasActivas: process.env.DESACTIVAR_TAREAS !== 'true',
}
