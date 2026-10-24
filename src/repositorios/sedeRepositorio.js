import { ejecutarSp, json } from '../config/db.js'

export const guardarSalon = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_salon_guardar', { p_org: org, p_id: id, p_datos: datos })
export const guardarSucursal = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_sucursal_guardar', { p_org: org, p_id: id, p_datos: datos })
export const guardarEspacio = (ctx, org, id, datos, horarios) =>
    ejecutarSp(ctx, 'sp_espacio_guardar', { p_org: org, p_id: id, p_datos: datos, p_horarios: json(horarios) })
export const horariosEspacio = (ctx, espacio) => ejecutarSp(ctx, 'sp_espacio_horarios', { p_espacio: espacio })
export const listarRecursos = (ctx, org) => ejecutarSp(ctx, 'sp_recursos_listar', { p_org: org })
export const guardarRecurso = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_recurso_guardar', { p_org: org, p_id: id, p_datos: datos })
export const listarFeriados = (ctx, org, desde, hasta) => ejecutarSp(ctx, 'sp_feriados_listar', { p_org: org, p_desde: desde, p_hasta: hasta })
export const crearFeriado = (ctx, org, fecha, nombre) => ejecutarSp(ctx, 'sp_feriado_crear', { p_org: org, p_fecha: fecha, p_nombre: nombre })
export const crearSalon = (ctx, org, datos) => ejecutarSp(ctx, 'sp_salon_crear', { p_org: org, p_datos: datos })
