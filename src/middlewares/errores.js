import { estadoHttp } from '../utilidades/errores.js'

export const noEncontrado = (req, res) => res.status(404).json({ code: 'RUTA', message: 'Ruta no encontrada.' })

// eslint-disable-next-line no-unused-vars
export const manejarErrores = (error, req, res, next) => {
    if (error.type === 'entity.parse.failed') return res.status(400).json({ code: 'JSON', message: 'El cuerpo no es JSON válido.' })
    const estado = estadoHttp(error)
    if (estado >= 500) console.error(`[error] ${req.method} ${req.originalUrl}:`, error)
    res.status(estado).json({
        code: error.code ?? 'ERROR',
        // Los mensajes internos (500) no se exponen.
        message: estado >= 500 && estado !== 503 ? 'Ocurrió un error inesperado. Probá de nuevo.' : error.message,
        details: estado >= 500 ? null : (error.detail ?? null),
        hint: estado >= 500 ? null : (error.hint ?? null),
    })
}
