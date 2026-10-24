// Error con estado HTTP propio (para validaciones de la API, no de la base).
export class ErrorApi extends Error {
    constructor(estado, code, message, hint) {
        super(message)
        this.estado = estado
        this.code = code
        this.hint = hint
    }
}

// SQLSTATE → HTTP. El cuerpo conserva { code, message, details, hint } como
// lo devolvía PostgREST, así el front traduce los errores igual que antes.
const ESTADOS = {
    '42501': 403, // sin permiso (RLS o exigir_permiso)
    P0002: 404, // no encontrado
    '23P01': 409, // superposición de agenda
    '23505': 409, // duplicado
    '23503': 409, // referencia en uso
    '23514': 400, // regla de validación
    '23502': 400, // falta un dato obligatorio
    '22023': 400, // valor inválido
    '22P02': 400, // formato inválido
    '22007': 400, // fecha inválida
    '22008': 400, // fecha fuera de rango
    '42883': 400, // faltan parámetros / no existe el SP
    P0001: 400, // regla de negocio (raise exception)
    '57014': 503, // statement_timeout
}

export const estadoHttp = (error) => error.estado ?? ESTADOS[error.code] ?? 500
