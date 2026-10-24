import express from 'express'
import * as registroControlador from '../controladores/registroControlador.js'
import * as sedeControlador from '../controladores/sedeControlador.js'
import * as clienteControlador from '../controladores/clienteControlador.js'
import * as reservaControlador from '../controladores/reservaControlador.js'
import * as cobroControlador from '../controladores/cobroControlador.js'
import * as tareaControlador from '../controladores/tareaControlador.js'
import * as ventaControlador from '../controladores/ventaControlador.js'
import * as equipoControlador from '../controladores/equipoControlador.js'

// Operaciones sobre un registro por su id (la organización sale del propio registro).
const router = express.Router()

router.get('/espacios/:id/horarios', sedeControlador.horariosEspacio)
router.get('/clientes/:id', clienteControlador.obtener)

router.get('/reservas/:id', reservaControlador.obtener)
router.get('/reservas/:id/ficha', reservaControlador.ficha)
router.patch('/reservas/:id/estado', reservaControlador.cambiarEstado)
router.patch('/reservas/:id/contrato', reservaControlador.cambiarContrato)
router.post('/reservas/:id/items', reservaControlador.agregarItem)
router.post('/reservas/:id/pagos', cobroControlador.registrarPago)
router.put('/reservas/:id/garantia', cobroControlador.pedirGarantia)
router.delete('/reservas/:id/garantia', cobroControlador.quitarGarantia)
router.post('/reservas/:id/garantia/cobro', cobroControlador.cobrarGarantia)
router.post('/reservas/:id/garantia/devolucion', cobroControlador.devolverGarantia)

router.get('/pagos/:id/comprobante', cobroControlador.comprobante)
router.patch('/pagos/:id/anular', cobroControlador.anularPago)

router.patch('/tareas/:id/estado', tareaControlador.cambiarEstado)
router.get('/presupuestos/:id', ventaControlador.obtenerPresupuesto)
router.post('/presupuestos/:id/aceptar', ventaControlador.aceptarPresupuesto)
router.get('/entrevistas/:id', ventaControlador.obtenerEntrevista)

router.patch('/membresias/:id', equipoControlador.actualizarMembresia)
router.delete('/invitaciones/:id', equipoControlador.revocarInvitacion)

// Genéricos: la lista de entidades permitidas está en los SP.
router.delete('/registros/:entidad/:id', registroControlador.eliminar)
router.patch('/registros/:entidad/:id/activo', registroControlador.activar)

export default router
