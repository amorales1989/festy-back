import { ejecutarSp } from '../config/db.js'

export const listar = (ctx, org, quien, estado) => ejecutarSp(ctx, 'sp_tareas_listar', { p_org: org, p_quien: quien, p_estado: estado })
export const guardar = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_tarea_guardar', { p_org: org, p_id: id, p_datos: datos })
export const cambiarEstado = (ctx, id, estado) => ejecutarSp(ctx, 'sp_tarea_estado', { p_id: id, p_estado: estado })
