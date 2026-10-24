import { entorno } from '../config/entorno.js'
import { ErrorApi } from '../utilidades/errores.js'

export const esAdminPlataforma = (req) => {
    const email = String(req.usuario?.claims?.email || '').toLowerCase()
    return Boolean(email) && entorno.adminsPlataforma.includes(email)
}

// Solo los emails configurados en ADMIN_PLATAFORMA (lo decide el servidor, no la app).
export const requiereAdminPlataforma = (req, res, next) =>
    esAdminPlataforma(req) ? next() : next(new ErrorApi(403, 'SOLO_ADMIN', 'Esta sección es solo para la administración de Festy.'))
