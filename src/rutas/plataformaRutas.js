import express from 'express'
import * as plataformaControlador from '../controladores/plataformaControlador.js'
import { requiereAdminPlataforma } from '../middlewares/adminPlataforma.js'

// Administración de la plataforma (dueño de Festy): /api/plataforma/...
const router = express.Router()

router.get('/yo', plataformaControlador.yo)
router.get('/empresas', requiereAdminPlataforma, plataformaControlador.listarEmpresas)
router.post('/empresas', requiereAdminPlataforma, plataformaControlador.crearEmpresa)

export default router
