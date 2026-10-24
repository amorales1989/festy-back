import express from 'express'
import * as plataformaControlador from '../controladores/plataformaControlador.js'
import { requiereAdminPlataforma } from '../middlewares/adminPlataforma.js'

// Administración de la plataforma (dueño de Festy): /api/plataforma/...
const router = express.Router()

router.get('/yo', plataformaControlador.yo)
router.get('/empresas', requiereAdminPlataforma, plataformaControlador.listarEmpresas)
router.post('/empresas', requiereAdminPlataforma, plataformaControlador.crearEmpresa)
router.put('/empresas/:id/precio', requiereAdminPlataforma, plataformaControlador.cambiarPrecio)
router.get('/empresas/:id/pagos', requiereAdminPlataforma, plataformaControlador.listarPagos)
router.post('/empresas/:id/pagos', requiereAdminPlataforma, plataformaControlador.registrarPago)
router.delete('/pagos/:id', requiereAdminPlataforma, plataformaControlador.eliminarPago)

export default router
