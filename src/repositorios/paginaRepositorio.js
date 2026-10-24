import { ejecutarSp, CONTEXTO_ANONIMO } from '../config/db.js'

export const guardar = (ctx, org, datos) => ejecutarSp(ctx, 'sp_pagina_guardar', { p_org: org, p_datos: datos })

// Página pública: sin sesión (rol anon). Los SP solo exponen datos de presentación y días ocupados.
export const salon = (slug) => ejecutarSp(CONTEXTO_ANONIMO, 'sp_publico_salon', { p_slug: slug })
export const ocupacion = (slug, desde, hasta) => ejecutarSp(CONTEXTO_ANONIMO, 'sp_publico_ocupacion', { p_slug: slug, p_desde: desde, p_hasta: hasta })
export const pedido = (slug, datos) => ejecutarSp(CONTEXTO_ANONIMO, 'sp_publico_pedido', { p_slug: slug, p_datos: datos })
