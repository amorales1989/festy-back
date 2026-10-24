import * as sesionRepositorio from '../repositorios/sesionRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'
import { ErrorApi } from '../utilidades/errores.js'
import * as cuentasServicio from '../servicios/cuentasServicio.js'
import { entorno } from '../config/entorno.js'
import { esAdminPlataforma } from '../middlewares/adminPlataforma.js'

export const obtenerPerfil = async (req, res) => res.json(await sesionRepositorio.obtenerPerfil(req.usuario))

export const elegirOrganizacion = async (req, res) => {
    await sesionRepositorio.elegirOrganizacion(req.usuario, req.body.organizacion_id)
    sinContenido(res)
}

export const listarOrganizaciones = async (req, res) => res.json(await sesionRepositorio.listarOrganizaciones(req.usuario))

export const crearOrganizacion = async (req, res) => {
    if (!entorno.altaLibreEmpresas && !esAdminPlataforma(req)) {
        throw new ErrorApi(403, 'ALTA_CERRADA', 'Las empresas las da de alta Festy. Comunicate con nosotros.')
    }
    const { nombre, zona_horaria } = req.body
    creado(res, { id: await sesionRepositorio.crearOrganizacion(req.usuario, nombre, zona_horaria) })
}

export const listarNotificaciones = async (req, res) => res.json(await sesionRepositorio.listarNotificaciones(req.usuario))

export const leerNotificaciones = async (req, res) => {
    await sesionRepositorio.leerNotificacion(req.usuario, opcional(req.body?.id))
    sinContenido(res)
}

export const registrarDispositivo = async (req, res) => {
    await sesionRepositorio.registrarDispositivo(req.usuario, req.body.token, req.body.plataforma)
    sinContenido(res)
}

export const quitarDispositivo = async (req, res) => {
    await sesionRepositorio.quitarDispositivo(req.usuario, req.params.token)
    sinContenido(res)
}

export const verInvitacion = async (req, res) => res.json(await sesionRepositorio.verInvitacion(req.params.token))

export const aceptarInvitacion = async (req, res) =>
    res.json({ organizacion_id: await sesionRepositorio.aceptarInvitacion(req.usuario, req.params.token) })

// Cuenta para un invitado (el registro público está cerrado): solo con una
// invitación válida y para el email al que se envió.
export const crearCuentaInvitado = async (req, res) => {
    const inv = await sesionRepositorio.verInvitacion(req.params.token)
    if (!inv?.valida) throw new ErrorApi(400, 'INVITACION', inv?.motivo || 'La invitación no es válida.')
    if (await cuentasServicio.usuarioPorEmail(inv.email)) {
        throw new ErrorApi(409, 'CUENTA_EXISTE', 'Ya tenés una cuenta con ese email: ingresá para aceptar la invitación.')
    }
    await cuentasServicio.crearUsuario({ email: inv.email, clave: req.body?.clave, nombre: String(req.body?.nombre || '').trim() || null })
    res.status(201).json({ email: inv.email })
}

// Empresas suspendidas del usuario (para mostrarle el aviso en lugar de "sin empresa").
export const empresasSuspendidas = async (req, res) => res.json(await sesionRepositorio.empresasSuspendidas(req.usuario))
