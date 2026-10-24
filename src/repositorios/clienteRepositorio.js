import { ejecutarSp } from '../config/db.js'

export const listar = (ctx, org, q, limite, desplazamiento) =>
    ejecutarSp(ctx, 'sp_clientes_listar', { p_org: org, p_q: q, p_limite: limite, p_desplazamiento: desplazamiento })
export const buscar = (ctx, org, q, limite) => ejecutarSp(ctx, 'sp_clientes_buscar', { p_org: org, p_q: q, p_limite: limite })
export const obtener = (ctx, id) => ejecutarSp(ctx, 'sp_cliente_obtener', { p_id: id })
export const guardar = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_cliente_guardar', { p_org: org, p_id: id, p_datos: datos })
