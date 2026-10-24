import * as clienteRepositorio from '../repositorios/clienteRepositorio.js'
import { creado } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'

export const listar = async (req, res) => {
    const { q, limite, desplazamiento } = req.query
    res.json(await clienteRepositorio.listar(req.usuario, req.params.org, opcional(q), opcional(limite), opcional(desplazamiento)))
}

export const buscar = async (req, res) =>
    res.json(await clienteRepositorio.buscar(req.usuario, req.params.org, req.query.q ?? '', opcional(req.query.limite)))

export const obtener = async (req, res) => res.json(await clienteRepositorio.obtener(req.usuario, req.params.id))

export const crear = async (req, res) => creado(res, await clienteRepositorio.guardar(req.usuario, req.params.org, null, req.body))

export const actualizar = async (req, res) => res.json(await clienteRepositorio.guardar(req.usuario, req.params.org, req.params.id, req.body))
