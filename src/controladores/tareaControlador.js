import * as tareaRepositorio from '../repositorios/tareaRepositorio.js'
import { sinContenido } from '../utilidades/respuestas.js'

export const listar = async (req, res) =>
    res.json(await tareaRepositorio.listar(req.usuario, req.params.org, req.query.quien ?? 'todas', req.query.estado ?? 'abiertas'))

export const crear = async (req, res) => {
    await tareaRepositorio.guardar(req.usuario, req.params.org, null, req.body)
    res.status(201).end()
}

export const actualizar = async (req, res) => {
    await tareaRepositorio.guardar(req.usuario, req.params.org, req.params.id, req.body)
    sinContenido(res)
}

export const cambiarEstado = async (req, res) => {
    await tareaRepositorio.cambiarEstado(req.usuario, req.params.id, req.body.estado)
    sinContenido(res)
}
