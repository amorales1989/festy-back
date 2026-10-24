import express from 'express'
import * as paginaControlador from '../controladores/paginaControlador.js'
import { limitarPorIp } from '../middlewares/limite.js'

// Página pública del salón: sin sesión. /api/publico/:slug/...
const router = express.Router()

router.get('/:slug', limitarPorIp({ maximo: 120, ventanaMs: 60_000 }), paginaControlador.salon)
router.get('/:slug/ocupacion', limitarPorIp({ maximo: 120, ventanaMs: 60_000 }), paginaControlador.ocupacion)
router.post('/:slug/pedidos', limitarPorIp({ maximo: 5, ventanaMs: 10 * 60_000 }), paginaControlador.pedido)

export default router
