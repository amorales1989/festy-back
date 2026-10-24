import * as sesionRepositorio from '../repositorios/sesionRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'

export const obtenerPerfil = async (req, res) => res.json(await sesionRepositorio.obtenerPerfil(req.usuario))

export const elegirOrganizacion = async (req, res) => {
    await sesionRepositorio.elegirOrganizacion(req.usuario, req.body.organizacion_id)
    sinContenido(res)
}

export const listarOrganizaciones = async (req, res) => res.json(await sesionRepositorio.listarOrganizaciones(req.usuario))

export const crearOrganizacion = async (req, res) => {
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
