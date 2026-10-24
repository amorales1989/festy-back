import * as reservaRepositorio from '../repositorios/reservaRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { booleano, nulo, opcional } from '../utilidades/valores.js'

const FILTROS = ['estado', 'contrato', 'desde', 'hasta', 'sucursal', 'texto']

export const listar = async (req, res) => {
    const filtros = Object.fromEntries(FILTROS.filter((f) => req.query[f] !== undefined).map((f) => [f, req.query[f]]))
    if (filtros.sucursal === '') delete filtros.sucursal
    res.json(await reservaRepositorio.listar(req.usuario, req.params.org, filtros, opcional(req.query.limite), opcional(req.query.desplazamiento)))
}

export const obtener = async (req, res) => res.json(await reservaRepositorio.obtener(req.usuario, req.params.id))

export const ficha = async (req, res) => res.json(await reservaRepositorio.ficha(req.usuario, req.params.id))

// Cuerpo: { datos, espacios }
export const crear = async (req, res) =>
    creado(res, { id: await reservaRepositorio.guardar(req.usuario, req.params.org, null, req.body.datos, req.body.espacios) })

export const actualizar = async (req, res) =>
    res.json({ id: await reservaRepositorio.guardar(req.usuario, req.params.org, req.params.id, req.body.datos, req.body.espacios) })

export const cambiarEstado = async (req, res) => {
    await reservaRepositorio.cambiarEstado(req.usuario, req.params.id, req.body.estado, opcional(req.body.motivo))
    sinContenido(res)
}

export const cambiarContrato = async (req, res) => {
    await reservaRepositorio.cambiarContrato(req.usuario, req.params.id, req.body.estado)
    sinContenido(res)
}

export const disponibilidad = async (req, res) => {
    const { espacios, inicio, fin, excluir, invitados } = req.body
    res.json(await reservaRepositorio.disponibilidad(req.usuario, req.params.org, {
        espacios, inicio, fin, excluir: opcional(excluir), invitados: opcional(invitados),
    }))
}

export const agregarItem = async (req, res) => creado(res, { id: await reservaRepositorio.agregarItem(req.usuario, req.params.id, req.body) })

export const agenda = async (req, res) => {
    const { inicio, fin, desde, hasta, sucursal, canceladas } = req.query
    res.json(await reservaRepositorio.agenda(req.usuario, req.params.org, {
        inicio, fin, desde, hasta, sucursal: opcional(sucursal), incluirCanceladas: booleano(canceladas),
    }))
}

export const crearBloqueos = async (req, res) => {
    const { espacios, inicio, fin, tipo, motivo } = req.body
    await reservaRepositorio.crearBloqueos(req.usuario, req.params.org, { espacios, inicio, fin, tipo, motivo: nulo(motivo) })
    res.status(201).end()
}
