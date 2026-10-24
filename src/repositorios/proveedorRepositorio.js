import { ejecutarSp } from '../config/db.js'

export const listar = (ctx, org) => ejecutarSp(ctx, 'sp_proveedores_listar', { p_org: org })
export const guardar = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_proveedor_guardar', { p_org: org, p_id: id, p_datos: datos })
export const costosEvento = (ctx, reserva) => ejecutarSp(ctx, 'sp_costos_evento', { p_reserva: reserva })
export const guardarCosto = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_costo_guardar', { p_org: org, p_id: id, p_datos: datos })
export const pagarCosto = (ctx, costo, datos) => ejecutarSp(ctx, 'sp_costo_pagar', { p_costo: costo, p_datos: datos })
export const costosDesdeCatalogo = (ctx, reserva) => ejecutarSp(ctx, 'sp_costos_desde_catalogo', { p_reserva: reserva })
export const rentabilidad = (ctx, org, desde, hasta) => ejecutarSp(ctx, 'sp_rentabilidad', { p_org: org, p_desde: desde, p_hasta: hasta })
