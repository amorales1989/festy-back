import { ejecutarSp } from '../config/db.js'

export const listarCuentas = (ctx, org) => ejecutarSp(ctx, 'sp_cuentas_listar', { p_org: org })
export const guardarCuenta = (ctx, org, id, datos) => ejecutarSp(ctx, 'sp_cuenta_guardar', { p_org: org, p_id: id, p_datos: datos })
export const resumen = (ctx, org, desde, hasta) => ejecutarSp(ctx, 'sp_caja', { p_org: org, p_desde: desde, p_hasta: hasta })
export const crearTransferencia = (ctx, org, datos) => ejecutarSp(ctx, 'sp_transferencia_crear', { p_org: org, p_datos: datos })
