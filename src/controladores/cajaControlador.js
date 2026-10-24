import * as cajaRepositorio from '../repositorios/cajaRepositorio.js'
import { creado } from '../utilidades/respuestas.js'

export const listarCuentas = async (req, res) => res.json(await cajaRepositorio.listarCuentas(req.usuario, req.params.org))

export const crearCuenta = async (req, res) => creado(res, await cajaRepositorio.guardarCuenta(req.usuario, req.params.org, null, req.body))

export const actualizarCuenta = async (req, res) =>
    res.json(await cajaRepositorio.guardarCuenta(req.usuario, req.params.org, req.params.id, req.body))

export const resumen = async (req, res) =>
    res.json(await cajaRepositorio.resumen(req.usuario, req.params.org, req.query.desde, req.query.hasta))

export const crearTransferencia = async (req, res) =>
    creado(res, { id: await cajaRepositorio.crearTransferencia(req.usuario, req.params.org, req.body) })
