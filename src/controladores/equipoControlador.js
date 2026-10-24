import * as equipoRepositorio from '../repositorios/equipoRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'

export const listarRoles = async (req, res) => res.json(await equipoRepositorio.listarRoles(req.usuario, req.params.org))

export const matrizRoles = async (req, res) => res.json(await equipoRepositorio.matrizRoles(req.usuario, req.params.org))

export const asignarPermiso = async (req, res) => {
    const { rol_id, permiso, asignar } = req.body
    await equipoRepositorio.asignarPermiso(req.usuario, req.params.org, rol_id, permiso, asignar === true)
    sinContenido(res)
}

export const listarInvitaciones = async (req, res) => res.json(await equipoRepositorio.listarInvitaciones(req.usuario, req.params.org))

export const crearInvitacion = async (req, res) =>
    creado(res, { token: await equipoRepositorio.crearInvitacion(req.usuario, req.params.org, req.body.email, req.body.rol_id) })

export const revocarInvitacion = async (req, res) => {
    await equipoRepositorio.revocarInvitacion(req.usuario, req.params.id)
    sinContenido(res)
}

export const actualizarMembresia = async (req, res) => {
    await equipoRepositorio.actualizarMembresia(req.usuario, req.params.id, req.body)
    sinContenido(res)
}

export const listarAuditoria = async (req, res) => {
    const { tabla, accion, limite, desplazamiento } = req.query
    res.json(await equipoRepositorio.listarAuditoria(req.usuario, req.params.org, {
        tabla: opcional(tabla), accion: opcional(accion), limite: opcional(limite), desplazamiento: opcional(desplazamiento),
    }))
}
