import { ejecutarSp, CONTEXTO_ANONIMO } from '../config/db.js'

export const obtenerPerfil = (ctx) => ejecutarSp(ctx, 'sp_perfil_obtener')
export const elegirOrganizacion = (ctx, org) => ejecutarSp(ctx, 'sp_perfil_elegir_organizacion', { p_org: org })
export const listarOrganizaciones = (ctx) => ejecutarSp(ctx, 'sp_organizaciones_listar')
export const crearOrganizacion = (ctx, nombre, zona) => ejecutarSp(ctx, 'sp_organizacion_crear', { p_nombre: nombre, p_zona_horaria: zona })
export const listarNotificaciones = (ctx) => ejecutarSp(ctx, 'sp_notificaciones_listar')
export const leerNotificacion = (ctx, id) => ejecutarSp(ctx, 'sp_notificacion_leer', { p_id: id })
export const registrarDispositivo = (ctx, token, plataforma) => ejecutarSp(ctx, 'sp_dispositivo_registrar', { p_token: token, p_plataforma: plataforma })
export const quitarDispositivo = (ctx, token) => ejecutarSp(ctx, 'sp_dispositivo_quitar', { p_token: token })
export const verInvitacion = (token) => ejecutarSp(CONTEXTO_ANONIMO, 'sp_invitacion_ver', { p_token: token })
export const aceptarInvitacion = (ctx, token) => ejecutarSp(ctx, 'sp_invitacion_aceptar', { p_token: token })
export const empresasSuspendidas = (ctx) => ejecutarSp(ctx, 'sp_mis_empresas_suspendidas')
