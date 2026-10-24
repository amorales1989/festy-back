import * as registroRepositorio from '../repositorios/registroRepositorio.js'
import { sinContenido } from '../utilidades/respuestas.js'

export const eliminar = async (req, res) => {
    await registroRepositorio.eliminar(req.usuario, req.params.entidad, req.params.id)
    sinContenido(res)
}

export const activar = async (req, res) => {
    await registroRepositorio.activar(req.usuario, req.params.entidad, req.params.id, req.body.activo === true)
    sinContenido(res)
}
