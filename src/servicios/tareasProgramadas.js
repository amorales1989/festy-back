import cron from 'node-cron'
import * as pushServicio from './pushServicio.js'

// Las tareas de negocio (vencer tentativas, recordatorios, purgas) siguen en
// pg_cron dentro de la base. Acá solo corre lo que necesita salir a internet.
export const iniciar = () => {
    if (!pushServicio.pushConfigurado()) {
        console.log('[tareas] Sin FIREBASE_SERVICE_ACCOUNT: no se envían notificaciones push.')
        return
    }
    let enCurso = false
    cron.schedule('* * * * *', async () => {
        if (enCurso) return
        enCurso = true
        try {
            const r = await pushServicio.enviarPendientes()
            if (r.notificaciones) console.log('[push]', r)
        } catch (error) {
            console.error('[push] Error al enviar:', error.message)
        } finally {
            enCurso = false
        }
    })
    console.log('[tareas] Envío de push programado cada minuto.')
}
