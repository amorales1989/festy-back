import { ejecutarSp } from '../config/db.js'

// La lista de entidades permitidas vive en los SP (sp_eliminar / sp_activar).
export const eliminar = (ctx, entidad, id) => ejecutarSp(ctx, 'sp_eliminar', { p_entidad: entidad, p_id: id })
export const activar = (ctx, entidad, id, activo) => ejecutarSp(ctx, 'sp_activar', { p_entidad: entidad, p_id: id, p_activo: activo })
