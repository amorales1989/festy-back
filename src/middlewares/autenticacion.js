import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify } from 'jose'
import { entorno } from '../config/entorno.js'
import { ErrorApi } from '../utilidades/errores.js'

const secreto = entorno.jwtSecreto ? new TextEncoder().encode(entorno.jwtSecreto) : null
const jwks = createRemoteJWKSet(new URL(entorno.urlJwks))
const opciones = { audience: 'authenticated', ...(entorno.jwtEmisor ? { issuer: entorno.jwtEmisor } : {}) }

const verificar = async (token) => {
    const { alg } = decodeProtectedHeader(token)
    if (alg?.startsWith('HS')) {
        if (!secreto) throw new Error('Token HS sin JWT_SECRET configurado')
        return (await jwtVerify(token, secreto, { ...opciones, algorithms: ['HS256'] })).payload
    }
    return (await jwtVerify(token, jwks, { ...opciones, algorithms: ['ES256', 'RS256'] })).payload
}

// Exige un token de sesión de GoTrue válido. El rol de base es siempre
// `authenticated`: el cliente nunca elige su rol.
export const requiereSesion = async (req, res, next) => {
    const [tipo, token] = (req.headers.authorization || '').split(' ')
    if (tipo !== 'Bearer' || !token) return next(new ErrorApi(401, 'NO_AUTENTICADO', 'Iniciá sesión para continuar.'))
    try {
        const claims = await verificar(token)
        if (!claims.sub) throw new Error('Token sin usuario')
        req.usuario = { rol: 'authenticated', claims: { ...claims, role: 'authenticated' } }
        next()
    } catch {
        next(new ErrorApi(401, 'SESION_INVALIDA', 'Tu sesión venció. Volvé a iniciar sesión.'))
    }
}
