import { ejecutarSp, CONTEXTO_SERVICIO } from '../config/db.js'

export const pendientes = (limite) => ejecutarSp(CONTEXTO_SERVICIO, 'sp_push_pendientes', { p_limite: limite })
export const marcar = (ids, tokensInvalidos) => ejecutarSp(CONTEXTO_SERVICIO, 'sp_push_marcar', { p_ids: ids, p_tokens_invalidos: tokensInvalidos })
