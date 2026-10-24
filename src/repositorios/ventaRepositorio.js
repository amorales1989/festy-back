import { ejecutarSp, json } from '../config/db.js'

export const listarServicios = (ctx, org, soloActivos) => ejecutarSp(ctx, 'sp_servicios_listar', { p_org: org, p_solo_activos: soloActivos })
export const guardarServicio = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_servicio_guardar', { p_org: org, p_id: id, p_datos: datos })
export const listarPresupuestos = (ctx, org, estado, texto) =>
    ejecutarSp(ctx, 'sp_presupuestos_listar', { p_org: org, p_estado: estado, p_texto: texto })
export const obtenerPresupuesto = (ctx, id) => ejecutarSp(ctx, 'sp_presupuesto_obtener', { p_id: id })
export const guardarPresupuesto = (ctx, org, id, datos, items) =>
    ejecutarSp(ctx, 'sp_presupuesto_guardar', { p_org: org, p_id: id, p_datos: datos, p_items: json(items) })
export const aceptarPresupuesto = (ctx, id, estado) => ejecutarSp(ctx, 'sp_presupuesto_aceptar', { p_id: id, p_estado: estado })

export const listarEntrevistas = (ctx, org, desde, hasta, estado) =>
    ejecutarSp(ctx, 'sp_entrevistas_listar', { p_org: org, p_desde: desde, p_hasta: hasta, p_estado: estado })
export const obtenerEntrevista = (ctx, id) => ejecutarSp(ctx, 'sp_entrevista_obtener', { p_id: id })
export const guardarEntrevista = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_entrevista_guardar', { p_org: org, p_id: id, p_datos: datos })
