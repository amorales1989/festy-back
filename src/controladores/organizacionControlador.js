import * as organizacionRepositorio from '../repositorios/organizacionRepositorio.js'
import { sinContenido } from '../utilidades/respuestas.js'
import { nulo, opcional } from '../utilidades/valores.js'

export const contexto = async (req, res) => res.json(await organizacionRepositorio.contexto(req.usuario, req.params.org))

export const actualizar = async (req, res) => res.json(await organizacionRepositorio.actualizar(req.usuario, req.params.org, req.body))

export const solicitarBaja = async (req, res) =>
    res.json({ eliminar_desde: await organizacionRepositorio.solicitarBaja(req.usuario, req.params.org, req.body.confirmacion) })

export const cancelarBaja = async (req, res) => {
    await organizacionRepositorio.cancelarBaja(req.usuario, req.params.org)
    sinContenido(res)
}

export const checklist = async (req, res) => res.json(await organizacionRepositorio.checklist(req.usuario, req.params.org))

export const cargarEjemplos = async (req, res) => res.json(await organizacionRepositorio.cargarEjemplos(req.usuario, req.params.org))

export const borrarEjemplos = async (req, res) => res.json(await organizacionRepositorio.borrarEjemplos(req.usuario, req.params.org))

export const panel = async (req, res) => {
    const { desde, hasta, salon, sucursal, responsable } = req.query
    res.json(await organizacionRepositorio.panel(req.usuario, req.params.org, {
        desde, hasta, salon: nulo(salon), sucursal: nulo(sucursal), responsable: nulo(responsable),
    }))
}

export const buscar = async (req, res) => res.json(await organizacionRepositorio.buscar(req.usuario, req.params.org, req.query.q ?? ''))

export const listarMiembros = async (req, res) => res.json(await organizacionRepositorio.listarMiembros(req.usuario, req.params.org))

export const exportar = async (req, res) => res.json(await organizacionRepositorio.exportar(req.usuario, req.params.org))

export const importarClientes = async (req, res) =>
    res.json(await organizacionRepositorio.importarClientes(req.usuario, req.params.org, req.body.filas ?? []))

export const importarReservas = async (req, res) =>
    res.json(await organizacionRepositorio.importarReservas(req.usuario, req.params.org, req.body.filas ?? []))

export const estadisticas = async (req, res) =>
    res.json(await organizacionRepositorio.estadisticas(req.usuario, req.params.org, req.query.desde, req.query.hasta, opcional(req.query.sucursal)))
