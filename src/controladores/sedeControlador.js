import * as sedeRepositorio from '../repositorios/sedeRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'

const id = (req) => req.params.id ?? null
const responder = (req, res, resultado) => (req.params.id ? res.json(resultado) : creado(res, resultado))

export const guardarSalon = async (req, res) =>
    responder(req, res, await sedeRepositorio.guardarSalon(req.usuario, req.params.org, id(req), req.body))

export const guardarSucursal = async (req, res) =>
    responder(req, res, await sedeRepositorio.guardarSucursal(req.usuario, req.params.org, id(req), req.body))

// Cuerpo: { datos, horarios? }
export const guardarEspacio = async (req, res) =>
    responder(req, res, await sedeRepositorio.guardarEspacio(req.usuario, req.params.org, id(req), req.body.datos, opcional(req.body.horarios)))

export const horariosEspacio = async (req, res) => res.json(await sedeRepositorio.horariosEspacio(req.usuario, req.params.id))

export const listarRecursos = async (req, res) => res.json(await sedeRepositorio.listarRecursos(req.usuario, req.params.org))

export const guardarRecurso = async (req, res) =>
    responder(req, res, await sedeRepositorio.guardarRecurso(req.usuario, req.params.org, id(req), req.body))

export const listarFeriados = async (req, res) =>
    res.json(await sedeRepositorio.listarFeriados(req.usuario, req.params.org, req.query.desde, req.query.hasta))

export const crearFeriado = async (req, res) => {
    await sedeRepositorio.crearFeriado(req.usuario, req.params.org, req.body.fecha, req.body.nombre)
    sinContenido(res)
}
