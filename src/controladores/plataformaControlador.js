import { ejecutarSp, CONTEXTO_SERVICIO } from '../config/db.js'
import * as cuentasServicio from '../servicios/cuentasServicio.js'
import { esAdminPlataforma } from '../middlewares/adminPlataforma.js'
import { ErrorApi } from '../utilidades/errores.js'

export const yo = (req, res) => res.json({ admin: esAdminPlataforma(req) })

export const listarEmpresas = async (req, res) => res.json(await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_empresas'))

// Alta de una empresa: crea (o reutiliza) la cuenta del dueño y su organización.
export const crearEmpresa = async (req, res) => {
    const { empresa, zona_horaria, nombre, email, clave } = req.body ?? {}
    const correo = String(email || '').trim().toLowerCase()
    if (String(empresa || '').trim().length < 2) throw new ErrorApi(400, 'EMPRESA', 'Ingresá el nombre de la empresa.')
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)) throw new ErrorApi(400, 'EMAIL', 'El email del dueño no es válido.')
    let usuarioId = await cuentasServicio.usuarioPorEmail(correo)
    const cuentaNueva = !usuarioId
    if (cuentaNueva) usuarioId = await cuentasServicio.crearUsuario({ email: correo, clave, nombre: String(nombre || '').trim() || null })
    const orgId = await ejecutarSp(cuentasServicio.contextoDe(usuarioId, correo), 'sp_organizacion_crear', {
        p_nombre: String(empresa).trim(), p_zona_horaria: zona_horaria || 'America/Argentina/Buenos_Aires',
    })
    res.status(201).json({ organizacion_id: orgId, usuario_id: usuarioId, cuenta_nueva: cuentaNueva })
}
