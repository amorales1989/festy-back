// Normalizan valores de query/body antes de pasarlos a un SP.
// opcional: vacío → undefined (se omite y aplica el default del SP).
// nulo:     vacío → null (el SP no tiene default para ese parámetro).
export const opcional = (v) => (v === '' || v === null || v === undefined ? undefined : v)
export const nulo = (v) => (v === '' || v === undefined ? null : v)
export const booleano = (v) => (v === undefined || v === '' ? undefined : v === true || v === 'true' || v === '1')
