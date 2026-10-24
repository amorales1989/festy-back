import { importPKCS8, SignJWT } from 'jose'
import * as pushRepositorio from '../repositorios/pushRepositorio.js'
import { entorno } from '../config/entorno.js'

// Envía por Firebase Cloud Messaging (API HTTP v1) las notificaciones que
// todavía no salieron por push. Reemplaza a la Edge Function enviar-push.

let cache = { token: null, vence: 0 }

const cuentaServicio = () => (entorno.firebaseCuenta ? JSON.parse(entorno.firebaseCuenta) : null)

const tokenDeAcceso = async (cuenta) => {
    if (cache.token && Date.now() < cache.vence) return cache.token
    const clave = await importPKCS8(cuenta.private_key, 'RS256')
    const asercion = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
        .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
        .setIssuer(cuenta.client_email)
        .setAudience('https://oauth2.googleapis.com/token')
        .setIssuedAt()
        .setExpirationTime('1h')
        .sign(clave)
    const r = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: asercion }),
    })
    if (!r.ok) throw new Error(`No se pudo obtener el token de Google: ${r.status} ${await r.text()}`)
    const { access_token, expires_in } = await r.json()
    cache = { token: access_token, vence: Date.now() + (expires_in - 300) * 1000 }
    return access_token
}

export const pushConfigurado = () => Boolean(entorno.firebaseCuenta)

export const enviarPendientes = async () => {
    const cuenta = cuentaServicio()
    if (!cuenta) return { notificaciones: 0, enviadas: 0, tokens_eliminados: 0 }
    const pendientes = await pushRepositorio.pendientes(200)
    if (!pendientes.length) return { notificaciones: 0, enviadas: 0, tokens_eliminados: 0 }

    const acceso = await tokenDeAcceso(cuenta)
    const invalidos = []
    let enviadas = 0
    for (const n of pendientes) {
        for (const token of n.tokens) {
            const r = await fetch(`https://fcm.googleapis.com/v1/projects/${cuenta.project_id}/messages:send`, {
                method: 'POST',
                headers: { Authorization: `Bearer ${acceso}`, 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    message: {
                        token,
                        notification: { title: n.titulo, body: n.cuerpo ?? '' },
                        data: { url: n.url ?? '/' },
                        android: { priority: 'high', notification: { channel_id: 'festy', sound: 'default' } },
                    },
                }),
            })
            if (r.ok) enviadas++
            else if (r.status === 404 || r.status === 400) invalidos.push(token) // token vencido o de otra app
        }
    }
    await pushRepositorio.marcar(pendientes.map((n) => n.id), invalidos)
    return { notificaciones: pendientes.length, enviadas, tokens_eliminados: invalidos.length }
}
