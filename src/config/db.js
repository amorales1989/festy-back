import pg from 'pg'
import { entorno } from './entorno.js'

export const pool = new pg.Pool({
    connectionString: entorno.urlBase,
    max: Number(process.env.DB_MAX_CONEXIONES || 10),
    idleTimeoutMillis: 30_000,
})

pool.on('error', (error) => console.error('[db] Error en una conexión inactiva:', error.message))

const NOMBRE_SP = /^sp_[a-z0-9_]+$/
const NOMBRE_PARAM = /^p_[a-z0-9_]+$/
const ROLES = new Set(['authenticated', 'anon', 'service_role'])

// Los arrays JS viajan como arrays de Postgres (uuid[], text[]). Para un
// parámetro jsonb que es una lista, el repositorio lo envuelve con json().
export const json = (valor) => (valor === null || valor === undefined ? valor : JSON.stringify(valor))

const aParametro = (valor) =>
    valor !== null && typeof valor === 'object' && !Array.isArray(valor) && !(valor instanceof Date) ? JSON.stringify(valor) : valor

// Ejecuta api.<nombre>(...) dentro de una transacción con la identidad del usuario.
// `contexto` = { rol, claims }. La RLS y auth.uid() funcionan igual que con PostgREST.
// `args` usa notación con nombre (p_org => $1); las claves undefined se omiten
// para que apliquen los valores por defecto del SP.
export const ejecutarSp = async (contexto, nombre, args = {}) => {
    if (!NOMBRE_SP.test(nombre)) throw new Error(`Nombre de SP inválido: ${nombre}`)
    if (!ROLES.has(contexto?.rol)) throw new Error('Rol de base inválido')
    const claves = Object.keys(args).filter((c) => args[c] !== undefined)
    for (const c of claves) if (!NOMBRE_PARAM.test(c)) throw new Error(`Parámetro inválido: ${c}`)
    const sql = `select api.${nombre}(${claves.map((c, i) => `${c} => $${i + 1}`).join(', ')}) as r`

    const cliente = await pool.connect()
    try {
        await cliente.query('begin')
        await cliente.query(
            "select set_config('role', $1, true), set_config('request.jwt.claims', $2, true), set_config('statement_timeout', '20s', true)",
            [contexto.rol, JSON.stringify(contexto.claims ?? { role: contexto.rol })]
        )
        const { rows } = await cliente.query(sql, claves.map((c) => aParametro(args[c])))
        await cliente.query('commit')
        return rows[0]?.r ?? null
    } catch (error) {
        await cliente.query('rollback').catch(() => {})
        throw error
    } finally {
        cliente.release()
    }
}

export const CONTEXTO_SERVICIO = { rol: 'service_role', claims: { role: 'service_role' } }
export const CONTEXTO_ANONIMO = { rol: 'anon', claims: { role: 'anon' } }
