import express from 'express'
import cors from 'cors'
import { entorno } from './config/entorno.js'
import { pool } from './config/db.js'
import { requiereSesion } from './middlewares/autenticacion.js'
import { manejarErrores, noEncontrado } from './middlewares/errores.js'
import * as sesionControlador from './controladores/sesionControlador.js'
import sesionRutas from './rutas/sesionRutas.js'
import organizacionRutas from './rutas/organizacionRutas.js'
import recursoRutas from './rutas/recursoRutas.js'

export const crearApp = () => {
    const app = express()
    app.disable('x-powered-by')
    app.set('trust proxy', 1)
    app.use(cors({ origin: entorno.origenes, maxAge: 86400 }))
    app.use(express.json({ limit: '5mb' })) // importaciones CSV grandes

    app.use((req, res, next) => {
        const inicio = Date.now()
        res.on('finish', () => console.log(`${new Date().toISOString()} ${req.method} ${req.originalUrl} ${res.statusCode} ${Date.now() - inicio}ms`))
        next()
    })

    app.get('/salud', async (req, res) => {
        try {
            await pool.query('select 1')
            res.json({ estado: 'ok' })
        } catch {
            res.status(503).json({ estado: 'sin base' })
        }
    })

    // Pública: ver los datos de una invitación antes de crear la cuenta.
    app.get('/api/invitaciones/:token', sesionControlador.verInvitacion)

    app.use('/api', requiereSesion)
    app.use('/api', sesionRutas)
    app.use('/api/organizaciones/:org', organizacionRutas)
    app.use('/api', recursoRutas)

    app.use(noEncontrado)
    app.use(manejarErrores)
    return app
}
