import * as cobroRepositorio from '../repositorios/cobroRepositorio.js'
import { creado, sinContenido } from '../utilidades/respuestas.js'
import { opcional } from '../utilidades/valores.js'

export const registrarPago = async (req, res) => creado(res, { id: await cobroRepositorio.registrarPago(req.usuario, req.params.id, req.body) })

export const anularPago = async (req, res) => {
    await cobroRepositorio.anularPago(req.usuario, req.params.id, req.body.motivo)
    sinContenido(res)
}

export const comprobante = async (req, res) => res.json(await cobroRepositorio.comprobante(req.usuario, req.params.id))

export const crearCuota = async (req, res) => {
    await cobroRepositorio.crearCuota(req.usuario, req.params.org, req.params.id, req.body)
    sinContenido(res)
}

// Cuerpo: { cuotas: [{ concepto, vencimiento, monto }] }
export const reemplazarCuotas = async (req, res) => {
    await cobroRepositorio.reemplazarCuotas(req.usuario, req.params.org, req.params.id, req.body.cuotas ?? [])
    sinContenido(res)
}

export const listarCobros = async (req, res) =>
    res.json(await cobroRepositorio.listarCobros(req.usuario, req.params.org, req.query.desde, req.query.hasta))

export const cuotasPendientes = async (req, res) =>
    res.json(await cobroRepositorio.cuotasPendientes(req.usuario, req.params.org, req.query.vista ?? 'proximos', req.query.hoy))

export const listarGarantias = async (req, res) => res.json(await cobroRepositorio.listarGarantias(req.usuario, req.params.org))

export const pedirGarantia = async (req, res) => res.json({ id: await cobroRepositorio.pedirGarantia(req.usuario, req.params.id, req.body.monto) })

export const quitarGarantia = async (req, res) => {
    await cobroRepositorio.quitarGarantia(req.usuario, req.params.id)
    sinContenido(res)
}

export const cobrarGarantia = async (req, res) => {
    const { fecha, medio, referencia, cuenta_id } = req.body
    res.json({ numero: await cobroRepositorio.cobrarGarantia(req.usuario, req.params.id, { fecha, medio, referencia: opcional(referencia), cuenta: opcional(cuenta_id) }) })
}

export const devolverGarantia = async (req, res) => {
    const { fecha, monto_devuelto, medio, motivo, cuenta_id } = req.body
    res.json({ numero: await cobroRepositorio.devolverGarantia(req.usuario, req.params.id, {
        fecha, monto_devuelto, medio, motivo: opcional(motivo), cuenta: opcional(cuenta_id),
    }) })
}

export const listarGastos = async (req, res) => {
    const { desde, hasta, categoria } = req.query
    res.json(await cobroRepositorio.listarGastos(req.usuario, req.params.org, desde, hasta, opcional(categoria)))
}

export const crearGasto = async (req, res) => {
    await cobroRepositorio.guardarGasto(req.usuario, req.params.org, null, req.body)
    res.status(201).end()
}

export const actualizarGasto = async (req, res) => {
    await cobroRepositorio.guardarGasto(req.usuario, req.params.org, req.params.id, req.body)
    sinContenido(res)
}
