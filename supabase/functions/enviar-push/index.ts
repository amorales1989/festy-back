// Edge Function: envía por Firebase Cloud Messaging (API HTTP v1) las
// notificaciones que todavía no salieron por push.
//
// Secretos necesarios (supabase secrets set …):
//   FIREBASE_SERVICE_ACCOUNT  JSON de la cuenta de servicio de Firebase (proyecto con la app Android)
//   PUSH_WEBHOOK_SECRETO      el mismo valor guardado en Vault como 'festy_push_secreto'
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los inyecta Supabase automáticamente.
import { createClient } from 'npm:@supabase/supabase-js@2'

interface CuentaServicio { project_id: string; client_email: string; private_key: string }

const b64url = (datos: ArrayBuffer | string) =>
  btoa(typeof datos === 'string' ? datos : String.fromCharCode(...new Uint8Array(datos))).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

async function tokenDeAcceso(cuenta: CuentaServicio): Promise<string> {
  const ahora = Math.floor(Date.now() / 1000)
  const encabezado = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const carga = b64url(JSON.stringify({
    iss: cuenta.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: ahora, exp: ahora + 3600,
  }))
  const pem = cuenta.private_key.replace(/-----[^-]+-----/g, '').replace(/\s/g, '')
  const clave = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const firma = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', clave, new TextEncoder().encode(`${encabezado}.${carga}`))
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${encabezado}.${carga}.${b64url(firma)}` }),
  })
  if (!r.ok) throw new Error(`No se pudo obtener el token de Google: ${r.status} ${await r.text()}`)
  return (await r.json()).access_token
}

Deno.serve(async (req) => {
  if (req.headers.get('x-festy-secreto') !== Deno.env.get('PUSH_WEBHOOK_SECRETO')) {
    return new Response('No autorizado', { status: 401 })
  }
  const cuenta = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT') ?? 'null') as CuentaServicio | null
  if (!cuenta) return new Response('Falta FIREBASE_SERVICE_ACCOUNT', { status: 500 })
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  const { data: pendientes, error } = await db.from('notificaciones')
    .select('id, usuario_id, titulo, cuerpo, url')
    .is('push_enviada_at', null).gt('creado_at', new Date(Date.now() - 2 * 864e5).toISOString())
    .order('creado_at').limit(200)
  if (error) return new Response(error.message, { status: 500 })
  if (!pendientes?.length) return Response.json({ enviadas: 0 })

  const usuarios = [...new Set(pendientes.map((n) => n.usuario_id))]
  const { data: dispositivos } = await db.from('dispositivos').select('usuario_id, token').in('usuario_id', usuarios).neq('plataforma', 'web')
  const acceso = await tokenDeAcceso(cuenta)
  const invalidos: string[] = []
  let enviadas = 0

  for (const n of pendientes) {
    for (const d of (dispositivos ?? []).filter((x) => x.usuario_id === n.usuario_id)) {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${cuenta.project_id}/messages:send`, {
        method: 'POST', headers: { Authorization: `Bearer ${acceso}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: {
          token: d.token,
          notification: { title: n.titulo, body: n.cuerpo ?? '' },
          data: { url: n.url ?? '/' },
          android: { priority: 'high', notification: { channel_id: 'festy', sound: 'default' } },
        } }),
      })
      if (r.ok) enviadas++
      else if (r.status === 404 || r.status === 400) invalidos.push(d.token)  // token vencido o de otra app
    }
  }
  await db.from('notificaciones').update({ push_enviada_at: new Date().toISOString() }).in('id', pendientes.map((n) => n.id))
  if (invalidos.length) await db.from('dispositivos').delete().in('token', invalidos)
  return Response.json({ notificaciones: pendientes.length, enviadas, tokens_eliminados: invalidos.length })
})
