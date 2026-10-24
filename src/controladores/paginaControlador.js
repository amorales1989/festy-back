import * as paginaRepositorio from '../repositorios/paginaRepositorio.js'

export const guardar = async (req, res) => res.json(await paginaRepositorio.guardar(req.usuario, req.params.org, req.body))

export const salon = async (req, res) => res.json(await paginaRepositorio.salon(req.params.slug))

export const ocupacion = async (req, res) => res.json(await paginaRepositorio.ocupacion(req.params.slug, req.query.desde, req.query.hasta))

export const pedido = async (req, res) => {
    // Campo trampa: los bots lo completan, las personas no lo ven.
    if (req.body?.sitio_web) return res.status(201).json({ ok: true })
    res.status(201).json(await paginaRepositorio.pedido(req.params.slug, req.body ?? {}))
}
