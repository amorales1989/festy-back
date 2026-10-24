import { ErrorApi } from '../utilidades/errores.js'

// Límite simple en memoria por IP (una sola instancia de la API).
// La base además limita pedidos por salón y por teléfono.
export const limitarPorIp = ({ maximo, ventanaMs }) => {
    const registros = new Map()
    setInterval(() => {
        const ahora = Date.now()
        for (const [ip, r] of registros) if (r.desde + ventanaMs < ahora) registros.delete(ip)
    }, ventanaMs).unref()
    return (req, res, next) => {
        const ahora = Date.now()
        const r = registros.get(req.ip)
        if (!r || r.desde + ventanaMs < ahora) {
            registros.set(req.ip, { desde: ahora, cantidad: 1 })
            return next()
        }
        if (++r.cantidad > maximo) {
            res.set('Retry-After', String(Math.ceil((r.desde + ventanaMs - ahora) / 1000)))
            return next(new ErrorApi(429, 'DEMASIADOS_PEDIDOS', 'Hiciste demasiados pedidos. Esperá unos minutos y volvé a probar.'))
        }
        next()
    }
}
