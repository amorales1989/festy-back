import { ejecutarSp, CONTEXTO_SERVICIO } from '../config/db.js'
import * as cuentasServicio from '../servicios/cuentasServicio.js'
import { esAdminPlataforma } from '../middlewares/adminPlataforma.js'
import { ErrorApi } from '../utilidades/errores.js'

export const yo = (req, res) => res.json({ admin: esAdminPlataforma(req) })

export const listarEmpresas = async (req, res) => res.json(await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_empresas'))

// Alta de una empresa: crea (o reutiliza) la cuenta del dueño y su organización.
export const crearEmpresa = async (req, res) => {
    const { empresa, zona_horaria, nombre, email, clave } = req.body ?? {}
    const correo = String(email || '').trim().toLowerCase()
    if (String(empresa || '').trim().length < 2) throw new ErrorApi(400, 'EMPRESA', 'Ingresá el nombre de la empresa.')
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)) throw new ErrorApi(400, 'EMAIL', 'El email del dueño no es válido.')
    let usuarioId = await cuentasServicio.usuarioPorEmail(correo)
    const cuentaNueva = !usuarioId
    if (cuentaNueva) usuarioId = await cuentasServicio.crearUsuario({ email: correo, clave, nombre: String(nombre || '').trim() || null })
    const orgId = await ejecutarSp(cuentasServicio.contextoDe(usuarioId, correo), 'sp_organizacion_crear', {
        p_nombre: String(empresa).trim(), p_zona_horaria: zona_horaria || 'America/Argentina/Buenos_Aires',
    })
    res.status(201).json({ organizacion_id: orgId, usuario_id: usuarioId, cuenta_nueva: cuentaNueva })
}

// --- Cobro de la suscripción (fuera de la app) ---------------------------------
export const cambiarPrecio = async (req, res) => {
    const precio = req.body?.precio === null || req.body?.precio === '' ? null : Number(req.body?.precio)
    if (precio !== null && !(precio >= 0)) throw new ErrorApi(400, 'PRECIO', 'El precio no es válido.')
    await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_precio', { p_org: req.params.id, p_precio: precio })
    res.status(204).end()
}

export const listarPagos = async (req, res) => res.json(await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_pagos', { p_org: req.params.id }))

export const registrarPago = async (req, res) =>
    res.status(201).json(await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_pago_registrar', {
        p_org: req.params.id, p_datos: req.body ?? {}, p_registrado_por: req.usuario.claims.email,
    }))

export const eliminarPago = async (req, res) => {
    await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_pago_eliminar', { p_id: req.params.id })
    res.status(204).end()
}

// Suspender (por falta de pago) o reactivar una empresa.
export const cambiarEstado = async (req, res) => {
    const { estado, motivo } = req.body ?? {}
    await ejecutarSp(CONTEXTO_SERVICIO, 'sp_plataforma_estado', { p_org: req.params.id, p_estado: estado, p_motivo: motivo ?? null })
    res.status(204).end()
}
