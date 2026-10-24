import { ejecutarSp, json } from '../config/db.js'

export const contexto = (ctx, org) => ejecutarSp(ctx, 'sp_organizacion_contexto', { p_org: org })
export const actualizar = (ctx, org, datos) => ejecutarSp(ctx, 'sp_organizacion_actualizar', { p_org: org, p_datos: datos })
export const cambiarPlan = (ctx, org, plan) => ejecutarSp(ctx, 'sp_plan_cambiar', { p_org: org, p_plan: plan })
export const solicitarBaja = (ctx, org, confirmacion) => ejecutarSp(ctx, 'sp_baja_solicitar', { p_org: org, p_confirmacion: confirmacion })
export const cancelarBaja = (ctx, org) => ejecutarSp(ctx, 'sp_baja_cancelar', { p_org: org })
export const checklist = (ctx, org) => ejecutarSp(ctx, 'sp_checklist', { p_org: org })
export const cargarEjemplos = (ctx, org) => ejecutarSp(ctx, 'sp_ejemplos_cargar', { p_org: org })
export const borrarEjemplos = (ctx, org) => ejecutarSp(ctx, 'sp_ejemplos_borrar', { p_org: org })
export const panel = (ctx, org, f) => ejecutarSp(ctx, 'sp_panel', {
    p_org: org, p_desde: f.desde, p_hasta: f.hasta, p_salon: f.salon, p_sucursal: f.sucursal, p_responsable: f.responsable,
})
export const buscar = (ctx, org, q) => ejecutarSp(ctx, 'sp_buscar', { p_org: org, p_q: q })
export const listarMiembros = (ctx, org) => ejecutarSp(ctx, 'sp_miembros_listar', { p_org: org })
export const exportar = (ctx, org) => ejecutarSp(ctx, 'sp_exportar', { p_org: org })
export const importarClientes = (ctx, org, filas) => ejecutarSp(ctx, 'sp_importar_clientes', { p_org: org, p_filas: json(filas) })
export const importarReservas = (ctx, org, filas) => ejecutarSp(ctx, 'sp_importar_reservas', { p_org: org, p_filas: json(filas) })
