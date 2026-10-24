import * as proveedorRepositorio from '../repositorios/proveedorRepositorio.js'
import { creado } from '../utilidades/respuestas.js'

export const listar = async (req, res) => res.json(await proveedorRepositorio.listar(req.usuario, req.params.org))

export const crear = async (req, res) => creado(res, await proveedorRepositorio.guardar(req.usuario, req.params.org, null, req.body))

export const actualizar = async (req, res) => res.json(await proveedorRepositorio.guardar(req.usuario, req.params.org, req.params.id, req.body))

export const costosEvento = async (req, res) => res.json(await proveedorRepositorio.costosEvento(req.usuario, req.params.id))

export const crearCosto = async (req, res) =>
    creado(res, { id: await proveedorRepositorio.guardarCosto(req.usuario, req.params.org, null, req.body) })

export const actualizarCosto = async (req, res) =>
    res.json({ id: await proveedorRepositorio.guardarCosto(req.usuario, req.params.org, req.params.id, req.body) })

// Registra un gasto vinculado al costo (impacta en la caja).
export const pagarCosto = async (req, res) => creado(res, { id: await proveedorRepositorio.pagarCosto(req.usuario, req.params.id, req.body) })

export const costosDesdeCatalogo = async (req, res) =>
    res.json({ creados: await proveedorRepositorio.costosDesdeCatalogo(req.usuario, req.params.id) })

export const rentabilidad = async (req, res) =>
    res.json(await proveedorRepositorio.rentabilidad(req.usuario, req.params.org, req.query.desde, req.query.hasta))
