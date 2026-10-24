import express from 'express'
import * as sesionControlador from '../controladores/sesionControlador.js'

const router = express.Router()

router.get('/perfil', sesionControlador.obtenerPerfil)
router.put('/perfil/organizacion', sesionControlador.elegirOrganizacion)
router.get('/organizaciones', sesionControlador.listarOrganizaciones)
router.post('/organizaciones', sesionControlador.crearOrganizacion)
router.get('/notificaciones', sesionControlador.listarNotificaciones)
router.post('/notificaciones/leer', sesionControlador.leerNotificaciones)
router.post('/dispositivos', sesionControlador.registrarDispositivo)
router.delete('/dispositivos/:token', sesionControlador.quitarDispositivo)
router.post('/invitaciones/:token/aceptar', sesionControlador.aceptarInvitacion)

export default router
