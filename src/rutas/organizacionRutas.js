import express from 'express'
import * as organizacionControlador from '../controladores/organizacionControlador.js'
import * as sedeControlador from '../controladores/sedeControlador.js'
import * as clienteControlador from '../controladores/clienteControlador.js'
import * as reservaControlador from '../controladores/reservaControlador.js'
import * as cobroControlador from '../controladores/cobroControlador.js'
import * as tareaControlador from '../controladores/tareaControlador.js'
import * as ventaControlador from '../controladores/ventaControlador.js'
import * as equipoControlador from '../controladores/equipoControlador.js'
import * as cajaControlador from '../controladores/cajaControlador.js'
import * as proveedorControlador from '../controladores/proveedorControlador.js'
import * as paginaControlador from '../controladores/paginaControlador.js'

// Todo lo que pertenece a una organización: /api/organizaciones/:org/...
// El aislamiento lo garantiza la base (RLS + permisos en cada SP).
const router = express.Router({ mergeParams: true })

// Organización
router.get('/contexto', organizacionControlador.contexto)
router.patch('/', organizacionControlador.actualizar)
router.post('/baja', organizacionControlador.solicitarBaja)
router.delete('/baja', organizacionControlador.cancelarBaja)
router.get('/checklist', organizacionControlador.checklist)
router.post('/ejemplos', organizacionControlador.cargarEjemplos)
router.delete('/ejemplos', organizacionControlador.borrarEjemplos)
router.get('/panel', organizacionControlador.panel)
router.get('/buscar', organizacionControlador.buscar)
router.get('/miembros', organizacionControlador.listarMiembros)
router.get('/exportar', organizacionControlador.exportar)
router.post('/importar/clientes', organizacionControlador.importarClientes)
router.post('/importar/reservas', organizacionControlador.importarReservas)

// Sedes
router.post('/salones', sedeControlador.guardarSalon)
router.put('/salones/:id', sedeControlador.guardarSalon)
router.post('/sucursales', sedeControlador.guardarSucursal)
router.put('/sucursales/:id', sedeControlador.guardarSucursal)
router.post('/espacios', sedeControlador.guardarEspacio)
router.put('/espacios/:id', sedeControlador.guardarEspacio)
router.get('/recursos', sedeControlador.listarRecursos)
router.post('/recursos', sedeControlador.guardarRecurso)
router.put('/recursos/:id', sedeControlador.guardarRecurso)
router.get('/feriados', sedeControlador.listarFeriados)
router.post('/feriados', sedeControlador.crearFeriado)

// Clientes
router.get('/clientes', clienteControlador.listar)
router.get('/clientes/buscar', clienteControlador.buscar)
router.post('/clientes', clienteControlador.crear)
router.put('/clientes/:id', clienteControlador.actualizar)

// Reservas y agenda
router.get('/reservas', reservaControlador.listar)
router.post('/reservas', reservaControlador.crear)
router.put('/reservas/:id', reservaControlador.actualizar)
router.post('/disponibilidad', reservaControlador.disponibilidad)
router.get('/agenda', reservaControlador.agenda)
router.post('/bloqueos', reservaControlador.crearBloqueos)

// Cobros, cuotas, garantías y gastos
router.get('/cobros', cobroControlador.listarCobros)
router.get('/cuotas', cobroControlador.cuotasPendientes)
router.post('/reservas/:id/cuotas', cobroControlador.crearCuota)
router.put('/reservas/:id/cuotas', cobroControlador.reemplazarCuotas)
router.get('/garantias', cobroControlador.listarGarantias)
router.get('/gastos', cobroControlador.listarGastos)
router.post('/gastos', cobroControlador.crearGasto)
router.put('/gastos/:id', cobroControlador.actualizarGasto)

// Caja por cuenta
router.get('/cuentas', cajaControlador.listarCuentas)
router.post('/cuentas', cajaControlador.crearCuenta)
router.put('/cuentas/:id', cajaControlador.actualizarCuenta)
router.get('/caja', cajaControlador.resumen)
router.post('/transferencias', cajaControlador.crearTransferencia)

// Proveedores, costos por evento y rentabilidad
router.get('/proveedores', proveedorControlador.listar)
router.post('/proveedores', proveedorControlador.crear)
router.put('/proveedores/:id', proveedorControlador.actualizar)
router.post('/costos', proveedorControlador.crearCosto)
router.put('/costos/:id', proveedorControlador.actualizarCosto)
router.get('/rentabilidad', proveedorControlador.rentabilidad)

// Página pública del salón (configuración)
router.put('/pagina', paginaControlador.guardar)
router.get('/pedidos-web', paginaControlador.pedidosPendientes)

// Tareas
router.get('/tareas', tareaControlador.listar)
router.post('/tareas', tareaControlador.crear)
router.put('/tareas/:id', tareaControlador.actualizar)

// Ventas: catálogo, presupuestos y entrevistas
router.get('/servicios', ventaControlador.listarServicios)
router.post('/servicios', ventaControlador.crearServicio)
router.put('/servicios/:id', ventaControlador.actualizarServicio)
router.get('/presupuestos', ventaControlador.listarPresupuestos)
router.post('/presupuestos', ventaControlador.crearPresupuesto)
router.put('/presupuestos/:id', ventaControlador.actualizarPresupuesto)
router.get('/entrevistas', ventaControlador.listarEntrevistas)
router.post('/entrevistas', ventaControlador.crearEntrevista)
router.put('/entrevistas/:id', ventaControlador.actualizarEntrevista)

// Equipo: roles, permisos, invitaciones y auditoría
router.get('/roles', equipoControlador.listarRoles)
router.get('/roles/matriz', equipoControlador.matrizRoles)
router.put('/roles/permisos', equipoControlador.asignarPermiso)
router.get('/invitaciones', equipoControlador.listarInvitaciones)
router.post('/invitaciones', equipoControlador.crearInvitacion)
router.get('/auditoria', equipoControlador.listarAuditoria)

export default router
