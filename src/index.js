import { crearApp } from './app.js'
import { entorno } from './config/entorno.js'
import { pool } from './config/db.js'
import * as tareasProgramadas from './servicios/tareasProgramadas.js'

process.on('unhandledRejection', (motivo) => console.error('[unhandledRejection]', motivo))

const servidor = crearApp().listen(entorno.puerto, () => {
    console.log(`API de Festy escuchando en el puerto ${entorno.puerto}`)
    if (entorno.tareasActivas) tareasProgramadas.iniciar()
})

const cerrar = () => {
    servidor.close(() => pool.end().finally(() => process.exit(0)))
    setTimeout(() => process.exit(1), 10_000).unref()
}
process.on('SIGTERM', cerrar)
process.on('SIGINT', cerrar)
