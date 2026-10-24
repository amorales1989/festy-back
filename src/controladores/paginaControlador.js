import * as paginaRepositorio from '../repositorios/paginaRepositorio.js'

export const guardar = async (req, res) => res.json(await paginaRepositorio.guardar(req.usuario, req.params.org, req.body))

export const salon = async (req, res) => res.json(await paginaRepositorio.salon(req.params.slug))

export const ocupacion = async (req, res) => res.json(await paginaRepositorio.ocupacion(req.params.slug, req.query.desde, req.query.hasta))

export const pedido = async (req, res) => {
    // Campo trampa: los bots lo completan, las personas no lo ven.
    if (req.body?.sitio_web) return res.status(201).json({ ok: true })
    res.status(201).json(await paginaRepositorio.pedido(req.params.slug, req.body ?? {}))
}

export const pedidosPendientes = async (req, res) => res.json(await paginaRepositorio.pedidosPendientes(req.usuario, req.params.org))

export const marcarAtendido = async (req, res) => {
    await paginaRepositorio.marcarAtendido(req.usuario, req.params.id)
    res.status(204).end()
}
