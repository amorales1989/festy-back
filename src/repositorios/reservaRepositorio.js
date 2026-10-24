import { ejecutarSp, json } from '../config/db.js'

export const listar = (ctx, org, filtros, limite, desplazamiento) =>
    ejecutarSp(ctx, 'sp_reservas_listar', { p_org: org, p_filtros: filtros, p_limite: limite, p_desplazamiento: desplazamiento })
export const obtener = (ctx, id) => ejecutarSp(ctx, 'sp_reserva_obtener', { p_id: id })
export const ficha = (ctx, id) => ejecutarSp(ctx, 'sp_reserva_ficha', { p_id: id })
export const guardar = (ctx, org, id, datos, espacios) =>
    ejecutarSp(ctx, 'sp_reserva_guardar', { p_org: org, p_id: id, p_datos: datos, p_espacios: json(espacios) })
export const cambiarEstado = (ctx, id, estado, motivo) => ejecutarSp(ctx, 'sp_reserva_estado', { p_id: id, p_estado: estado, p_motivo: motivo })
export const cambiarContrato = (ctx, id, estado) => ejecutarSp(ctx, 'sp_reserva_contrato', { p_id: id, p_estado: estado })
export const disponibilidad = (ctx, org, d) => ejecutarSp(ctx, 'sp_disponibilidad', {
    p_org: org, p_espacios: d.espacios, p_inicio: d.inicio, p_fin: d.fin, p_excluir: d.excluir, p_invitados: d.invitados,
})
export const agregarItem = (ctx, reserva, datos) => ejecutarSp(ctx, 'sp_reserva_item_agregar', { p_reserva: reserva, p_datos: datos })
export const agenda = (ctx, org, f) => ejecutarSp(ctx, 'sp_agenda', {
    p_org: org, p_inicio: f.inicio, p_fin: f.fin, p_desde: f.desde, p_hasta: f.hasta, p_sucursal: f.sucursal, p_incluir_canceladas: f.incluirCanceladas,
})
export const crearBloqueos = (ctx, org, b) => ejecutarSp(ctx, 'sp_bloqueos_crear', {
    p_org: org, p_espacios: b.espacios, p_inicio: b.inicio, p_fin: b.fin, p_tipo: b.tipo, p_motivo: b.motivo,
})
