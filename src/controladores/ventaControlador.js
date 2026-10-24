import * as ventaRepositorio from '../repositorios/ventaRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { booleano, opcional } from '../utilidades/valores.js'

export const listarServicios = async (req, res) =>
    res.json(await ventaRepositorio.listarServicios(req.usuario, req.params.org, booleano(req.query.activos)))

export const crearServicio = async (req, res) => {
    await ventaRepositorio.guardarServicio(req.usuario, req.params.org, null, req.body)
    res.status(201).end()
}

export const actualizarServicio = async (req, res) => {
    await ventaRepositorio.guardarServicio(req.usuario, req.params.org, req.params.id, req.body)
    sinContenido(res)
}

export const listarPresupuestos = async (req, res) =>
    res.json(await ventaRepositorio.listarPresupuestos(req.usuario, req.params.org, req.query.estado, opcional(req.query.texto)))

export const obtenerPresupuesto = async (req, res) => res.json(await ventaRepositorio.obtenerPresupuesto(req.usuario, req.params.id))

// Cuerpo: { datos, items }
export const crearPresupuesto = async (req, res) =>
    creado(res, { id: await ventaRepositorio.guardarPresupuesto(req.usuario, req.params.org, null, req.body.datos, req.body.items ?? []) })

export const actualizarPresupuesto = async (req, res) =>
    res.json({ id: await ventaRepositorio.guardarPresupuesto(req.usuario, req.params.org, req.params.id, req.body.datos, req.body.items ?? []) })

// Convierte el presupuesto en evento. Devuelve el id de la reserva creada.
export const aceptarPresupuesto = async (req, res) =>
    res.json({ reserva_id: await ventaRepositorio.aceptarPresupuesto(req.usuario, req.params.id, req.body.estado) })

export const listarEntrevistas = async (req, res) => {
    const { desde, hasta, estado } = req.query
    res.json(await ventaRepositorio.listarEntrevistas(req.usuario, req.params.org, desde, hasta, opcional(estado)))
}

export const obtenerEntrevista = async (req, res) => res.json(await ventaRepositorio.obtenerEntrevista(req.usuario, req.params.id))

export const crearEntrevista = async (req, res) => {
    await ventaRepositorio.guardarEntrevista(req.usuario, req.params.org, null, req.body)
    res.status(201).end()
}

export const actualizarEntrevista = async (req, res) => {
    await ventaRepositorio.guardarEntrevista(req.usuario, req.params.org, req.params.id, req.body)
    sinContenido(res)
}
