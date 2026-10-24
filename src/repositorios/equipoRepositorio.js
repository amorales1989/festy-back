import { ejecutarSp } from '../config/db.js'

export const listarRoles = (ctx, org) => ejecutarSp(ctx, 'sp_roles_listar', { p_org: org })
export const matrizRoles = (ctx, org) => ejecutarSp(ctx, 'sp_roles_matriz', { p_org: org })
export const asignarPermiso = (ctx, org, rol, permiso, asignar) =>
    ejecutarSp(ctx, 'sp_rol_permiso', { p_org: org, p_rol: rol, p_permiso: permiso, p_asignar: asignar })
export const listarInvitaciones = (ctx, org) => ejecutarSp(ctx, 'sp_invitaciones_listar', { p_org: org })
export const crearInvitacion = (ctx, org, email, rol) => ejecutarSp(ctx, 'sp_invitacion_crear', { p_org: org, p_email: email, p_rol: rol })
export const revocarInvitacion = (ctx, id) => ejecutarSp(ctx, 'sp_invitacion_revocar', { p_id: id })
export const actualizarMembresia = (ctx, id, datos) => ejecutarSp(ctx, 'sp_membresia_actualizar', { p_id: id, p_datos: datos })
export const listarAuditoria = (ctx, org, f) => ejecutarSp(ctx, 'sp_auditoria_listar', {
    p_org: org, p_tabla: f.tabla, p_accion: f.accion, p_limite: f.limite, p_desplazamiento: f.desplazamiento,
})
