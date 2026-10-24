import { ejecutarSp, json } from '../config/db.js'

export const registrarPago = (ctx, reserva, datos) => ejecutarSp(ctx, 'sp_pago_registrar', { p_reserva: reserva, p_datos: datos })
export const anularPago = (ctx, id, motivo) => ejecutarSp(ctx, 'sp_pago_anular', { p_id: id, p_motivo: motivo })
export const comprobante = (ctx, pago) => ejecutarSp(ctx, 'sp_comprobante', { p_pago: pago })
export const crearCuota = (ctx, org, reserva, c) => ejecutarSp(ctx, 'sp_cuota_crear', {
    p_org: org, p_reserva: reserva, p_concepto: c.concepto, p_vencimiento: c.vencimiento, p_monto: c.monto,
})
export const reemplazarCuotas = (ctx, org, reserva, cuotas) =>
    ejecutarSp(ctx, 'sp_cuotas_reemplazar', { p_org: org, p_reserva: reserva, p_cuotas: json(cuotas) })
export const listarCobros = (ctx, org, desde, hasta) => ejecutarSp(ctx, 'sp_cobros_listar', { p_org: org, p_desde: desde, p_hasta: hasta })
export const cuotasPendientes = (ctx, org, vista, hoy) => ejecutarSp(ctx, 'sp_cuotas_pendientes', { p_org: org, p_vista: vista, p_hoy: hoy })

export const listarGarantias = (ctx, org) => ejecutarSp(ctx, 'sp_garantias_listar', { p_org: org })
export const pedirGarantia = (ctx, reserva, monto) => ejecutarSp(ctx, 'sp_garantia_pedir', { p_reserva: reserva, p_monto: monto })
export const quitarGarantia = (ctx, reserva) => ejecutarSp(ctx, 'sp_garantia_quitar', { p_reserva: reserva })
export const cobrarGarantia = (ctx, reserva, d) => ejecutarSp(ctx, 'sp_garantia_cobrar', {
    p_reserva: reserva, p_fecha: d.fecha, p_medio: d.medio, p_referencia: d.referencia,
})
export const devolverGarantia = (ctx, reserva, d) => ejecutarSp(ctx, 'sp_garantia_devolver', {
    p_reserva: reserva, p_fecha: d.fecha, p_monto_devuelto: d.monto_devuelto, p_medio: d.medio, p_motivo: d.motivo,
})

export const listarGastos = (ctx, org, desde, hasta, categoria) =>
    ejecutarSp(ctx, 'sp_gastos_listar', { p_org: org, p_desde: desde, p_hasta: hasta, p_categoria: categoria })
export const guardarGasto = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_gasto_guardar', { p_org: org, p_id: id, p_datos: datos })
