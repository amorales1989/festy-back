import { entorno } from '../config/entorno.js'
import { ejecutarSp, CONTEXTO_SERVICIO } from '../config/db.js'
import { ErrorApi } from '../utilidades/errores.js'

// Cuentas de usuario. El registro público está cerrado: las cuentas se crean
// acá, con la API de administración de GoTrue (email ya confirmado).

export const usuarioPorEmail = (email) => ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_usuario_por_email', { p_email: email })

export const crearUsuario = async ({ email, clave, nombre }) => {
    if (!entorno.claveAuthAdmin) throw new Error('Falta AUTH_ADMIN_KEY para crear cuentas')
    if (!clave || clave.length < 8) throw new ErrorApi(400, 'CLAVE', 'La contraseña debe tener al menos 8 caracteres.')
    const r = await fetch(`${entorno.urlAuthAdmin}/admin/users`, {
        method: 'POST',
        headers: { apikey: entorno.claveAuthAdmin, Authorization: `Bearer ${entorno.claveAuthAdmin}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: clave, email_confirm: true, user_metadata: { nombre } }),
    })
    const cuerpo = await r.json().catch(() => ({}))
    if (!r.ok) {
        const msg = String(cuerpo.msg || cuerpo.message || cuerpo.error_description || '')
        if (r.status === 422 && /already|registered|exists/i.test(msg)) throw new ErrorApi(409, 'CUENTA_EXISTE', 'Ya existe una cuenta con ese email.')
        if (/password/i.test(msg)) throw new ErrorApi(400, 'CLAVE', 'La contraseña no es válida (mínimo 8 caracteres).')
        if (/email/i.test(msg)) throw new ErrorApi(400, 'EMAIL', 'El email no es válido.')
        throw new Error(`GoTrue ${r.status}: ${msg}`)
    }
    return cuerpo.id
}

/** Contexto de base de datos "como" un usuario (para crear su organización con su identidad). */
export const contextoDe = (usuarioId, email) => ({ rol: 'authenticated', claims: { sub: usuarioId, role: 'authenticated', email } })
