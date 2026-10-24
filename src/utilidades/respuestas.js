// Respuestas comunes de los controladores.
export const sinContenido = (res) => res.status(204).end()
export const creado = (res, cuerpo) => res.status(201).json(cuerpo)
