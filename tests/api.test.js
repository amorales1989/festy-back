// Pruebas de punta a punta de la API contra el Supabase local (supabase start).
// Crean dos cuentas nuevas en GoTrue y verifican flujo, permisos y aislamiento.
import { after, before, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { execSync } from 'node:child_process'

process.env.DATABASE_URL ??= 'postgresql://authenticator:postgres@127.0.0.1:64322/postgres'
process.env.AUTH_URL ??= 'http://127.0.0.1:64321'
process.env.DESACTIVAR_TAREAS = 'true'
const sufijoAdmin = Date.now()
process.env.ADMIN_PLATAFORMA = `admin-${sufijoAdmin}@api.test`
process.env.AUTH_ADMIN_KEY ??= execSync('supabase status -o env', { encoding: 'utf8' }).match(/^SERVICE_ROLE_KEY="(.*)"$/m)?.[1]

const { crearApp } = await import('../src/app.js')
const { pool } = await import('../src/config/db.js')

const AUTH = process.env.AUTH_URL
const CLAVE = process.env.SUPABASE_PUBLISHABLE_KEY ??
    execSync('supabase status -o env', { encoding: 'utf8' }).match(/^PUBLISHABLE_KEY="(.*)"$/m)?.[1]

let servidor, base
const sufijo = Date.now()

const cuenta = async (email) => {
    const r = await fetch(`${AUTH}/auth/v1/signup`, {
        method: 'POST', headers: { apikey: CLAVE, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: 'clave-de-prueba-1', data: { nombre: email.split('@')[0] } }),
    })
    const cuerpo = await r.json()
    assert.ok(cuerpo.access_token, `no se pudo crear ${email}: ${JSON.stringify(cuerpo)}`)
    return cuerpo.access_token
}

const llamar = (token) => async (metodo, ruta, cuerpo) => {
    const r = await fetch(`${base}${ruta}`, {
        method: metodo,
        headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
        body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
    })
    const texto = await r.text()
    return { estado: r.status, datos: texto ? JSON.parse(texto) : null }
}

let duenia, intruso, org, sucursal, espacio, cliente, reserva

before(async () => {
    servidor = crearApp().listen(0)
    base = `http://127.0.0.1:${servidor.address().port}`
    duenia = llamar(await cuenta(`duenia-${sufijo}@api.test`))
    intruso = llamar(await cuenta(`intruso-${sufijo}@api.test`))
})

after(async () => {
    servidor.close()
    // Limpieza: la organización de prueba y las cuentas (como superusuario).
    const admin = new (await import('pg')).default.Client('postgresql://postgres:postgres@127.0.0.1:64322/postgres')
    await admin.connect()
    if (org) {
        await admin.query('delete from public.garantias where organizacion_id = $1', [org])
        await admin.query('delete from public.pagos where organizacion_id = $1', [org])
        await admin.query('delete from public.reservas where organizacion_id = $1', [org])
        await admin.query('delete from public.organizaciones where id = $1', [org])
    }
    await admin.query('delete from public.reservas where organizacion_id in (select organizacion_id from public.membresias m join auth.users u on u.id = m.usuario_id where u.email like $1)', [`nuevo-duenio-${sufijo}@api.test`])
    await admin.query('delete from public.organizaciones where creado_por in (select id from auth.users where email like $1)', [`nuevo-duenio-${sufijo}@api.test`])
    await admin.query("delete from auth.users where email like $1 or email like $2", [`%-${sufijo}@api.test`, `admin-%@api.test`])
    await admin.end()
    await pool.end()
})

describe('autenticación', () => {
    test('sin token responde 401', async () => {
        assert.equal((await llamar(null)('GET', '/api/perfil')).estado, 401)
    })
    test('token adulterado responde 401', async () => {
        assert.equal((await llamar('a.b.c')('GET', '/api/perfil')).estado, 401)
    })
    test('salud', async () => {
        assert.deepEqual((await llamar(null)('GET', '/salud')).datos, { estado: 'ok' })
    })
})

describe('flujo principal', () => {
    test('crea la organización y sus sedes', async () => {
        const r = await duenia('POST', '/api/organizaciones', { nombre: 'Salón Prueba API', zona_horaria: 'America/Argentina/Buenos_Aires' })
        assert.equal(r.estado, 201)
        org = r.datos.id
        const salon = await duenia('POST', `/api/organizaciones/${org}/salones`, { nombre: 'Marca' })
        assert.equal(salon.estado, 201)
        sucursal = (await duenia('POST', `/api/organizaciones/${org}/sucursales`, { salon_id: salon.datos.id, nombre: 'Centro' })).datos.id
        const e = await duenia('POST', `/api/organizaciones/${org}/espacios`, { datos: { sucursal_id: sucursal, nombre: 'Salón A', capacidad_maxima: 200 } })
        assert.equal(e.estado, 201)
        espacio = e.datos.id
        const ctx = await duenia('GET', `/api/organizaciones/${org}/contexto`)
        assert.equal(ctx.datos.espacios.length, 1)
        assert.ok(ctx.datos.permisos.includes('pagos.registrar'))
    })

    test('alta de cliente y evento', async () => {
        const c = await duenia('POST', `/api/organizaciones/${org}/clientes`, { nombre: 'Laura Pérez', telefono: '1144443333' })
        assert.equal(c.estado, 201, JSON.stringify(c.datos))
        cliente = c.datos.id
        const r = await duenia('POST', `/api/organizaciones/${org}/reservas`, {
            datos: { sucursal_id: sucursal, cliente_id: cliente, titulo: 'Boda Pérez', estado: 'confirmada',
                     inicio: '2027-09-11T21:00:00-03:00', fin: '2027-09-12T05:00:00-03:00', invitados: 150, precio_total: 2000000 },
            espacios: [{ espacio_id: espacio }],
        })
        assert.equal(r.estado, 201, JSON.stringify(r.datos))
        reserva = r.datos.id
        const lista = await duenia('GET', `/api/organizaciones/${org}/reservas?estado=&texto=Boda`)
        assert.equal(lista.datos.total, 1)
    })

    test('la superposición devuelve 409 con el código de la base', async () => {
        const r = await duenia('POST', `/api/organizaciones/${org}/reservas`, {
            datos: { sucursal_id: sucursal, cliente_id: cliente, titulo: 'Pisada', estado: 'confirmada',
                     inicio: '2027-09-11T23:00:00-03:00', fin: '2027-09-12T02:00:00-03:00' },
            espacios: [{ espacio_id: espacio }],
        })
        assert.equal(r.estado, 409)
        assert.equal(r.datos.code, '23P01')
    })

    test('cobro, comprobante y saldo', async () => {
        const p = await duenia('POST', `/api/reservas/${reserva}/pagos`, { monto: 500000, fecha: '2027-01-05', medio: 'transferencia', concepto: 'sena' })
        assert.equal(p.estado, 201)
        const c = await duenia('GET', `/api/pagos/${p.datos.id}/comprobante`)
        assert.equal(c.datos.numero_comprobante, 1)
        const ficha = await duenia('GET', `/api/reservas/${reserva}/ficha`)
        assert.equal(ficha.datos.saldo.saldo, 1500000)
    })

    test('garantía: pedir, cobrar y devolver', async () => {
        assert.equal((await duenia('PUT', `/api/reservas/${reserva}/garantia`, { monto: 200000 })).estado, 200)
        const cobro = await duenia('POST', `/api/reservas/${reserva}/garantia/cobro`, { fecha: '2027-09-01', medio: 'efectivo' })
        assert.equal(cobro.datos.numero, 1)
        const dev = await duenia('POST', `/api/reservas/${reserva}/garantia/devolucion`,
            { fecha: '2027-09-13', monto_devuelto: 150000, medio: 'efectivo', motivo: 'Vajilla rota' })
        assert.equal(dev.estado, 200)
        const g = await duenia('GET', `/api/organizaciones/${org}/garantias`)
        assert.equal(g.datos[0].estado, 'retenida')
    })

    test('borrado genérico respeta la lista permitida', async () => {
        assert.equal((await duenia('DELETE', `/api/registros/perfiles/${cliente}`)).estado, 400)
    })
})

describe('aislamiento entre organizaciones', () => {
    test('otra cuenta no ve ni modifica nada', async () => {
        assert.deepEqual((await intruso('GET', '/api/organizaciones')).datos, [])
        assert.equal((await intruso('GET', `/api/organizaciones/${org}/reservas?estado=`)).datos.total, 0)
        assert.equal((await intruso('GET', `/api/reservas/${reserva}`)).estado, 404)
        assert.equal((await intruso('DELETE', `/api/registros/reservas/${reserva}`)).estado, 403)
        const pago = await intruso('POST', `/api/reservas/${reserva}/pagos`, { monto: 1, fecha: '2027-01-05', medio: 'efectivo', concepto: 'cuota' })
        assert.ok(pago.estado >= 400 && pago.estado < 500)
        assert.equal((await intruso('PATCH', `/api/reservas/${reserva}/estado`, { estado: 'cancelada' })).estado, 403)
        const exp = await intruso('GET', `/api/organizaciones/${org}/exportar`)
        assert.equal(exp.datos.reservas, null)
    })
})

describe('caja, proveedores y página pública', () => {
    test('caja por cuenta con cobro y pago a proveedor', async () => {
        const cuentas = (await duenia('GET', `/api/organizaciones/${org}/cuentas`)).datos
        assert.equal(cuentas.length, 3)
        const prov = await duenia('POST', `/api/organizaciones/${org}/proveedores`, { nombre: 'Sonido Sur' })
        assert.equal(prov.estado, 201)
        const costo = await duenia('POST', `/api/organizaciones/${org}/costos`, { reserva_id: reserva, proveedor_id: prov.datos.id, descripcion: 'Sonido', monto: 300000 })
        assert.equal(costo.estado, 201)
        assert.equal((await duenia('POST', `/api/costos/${costo.datos.id}/pagos`, { fecha: '2027-02-01', monto: 100000, medio: 'efectivo' })).estado, 201)
        const c = (await duenia('GET', `/api/reservas/${reserva}/costos`)).datos
        assert.equal(c.costos[0].pendiente, 200000)
        assert.equal(c.ganancia, 1700000)
        const caja = (await duenia('GET', `/api/organizaciones/${org}/caja?desde=2027-01-01&hasta=2027-12-31`)).datos
        // Efectivo: garantía cobrada 200.000 − devuelta 150.000 (prueba anterior) − pago al proveedor 100.000
        assert.equal(caja.cuentas.find((x) => x.nombre === 'Efectivo').saldo, -50000)
        const rent = (await duenia('GET', `/api/organizaciones/${org}/rentabilidad?desde=2027-09-01&hasta=2027-09-30`)).datos
        assert.equal(rent.totales.ganancia, 1700000)
    })

    test('página pública: sin sesión ve el salón y deja un pedido', async () => {
        const slug = `salon-api-${sufijo}`
        assert.equal((await llamar(null)('GET', `/api/publico/${slug}`)).estado, 404)
        assert.equal((await duenia('PUT', `/api/organizaciones/${org}/pagina`, { pagina_slug: slug, pagina_activa: true, pagina_whatsapp: '5491155550000' })).estado, 200)
        const salon = await llamar(null)('GET', `/api/publico/${slug}`)
        assert.equal(salon.datos.nombre, 'Salón Prueba API')
        const ocup = await llamar(null)('GET', `/api/publico/${slug}/ocupacion?desde=2027-09-01&hasta=2027-09-30`)
        assert.deepEqual(ocup.datos.map((d) => d.fecha), ['2027-09-11'])
        const pedido = await llamar(null)('POST', `/api/publico/${slug}/pedidos`, {
            nombre: 'Juan Web', telefono: '1166667777', fecha: '2027-10-02', espacio_id: espacio, invitados: 50,
        })
        assert.equal(pedido.estado, 201)
        assert.equal(pedido.datos.ok, true)
        const pendientes = (await duenia('GET', `/api/organizaciones/${org}/pedidos-web`)).datos
        assert.equal(pendientes[0].telefono, '1166667777')
        assert.equal((await duenia('POST', `/api/reservas/${pendientes[0].id}/pedido-web/atendido`)).estado, 204)
        assert.equal((await duenia('GET', `/api/organizaciones/${org}/pedidos-web`)).datos.length, 0)
        assert.equal((await llamar(null)('GET', `/api/organizaciones/${org}/caja?desde=2027-01-01&hasta=2027-12-31`)).estado, 401)
    })
})

describe('cuentas: alta de empresas por el administrador e invitados', () => {
    let admin
    const ingresar = async (email, password) => {
        const r = await fetch(`${AUTH}/auth/v1/token?grant_type=password`, {
            method: 'POST', headers: { apikey: CLAVE, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }),
        })
        return (await r.json()).access_token
    }

    test('solo el administrador de la plataforma da de alta empresas', async () => {
        assert.deepEqual((await duenia('GET', '/api/plataforma/yo')).datos, { admin: false })
        assert.equal((await duenia('GET', '/api/plataforma/empresas')).estado, 403)
        assert.equal((await duenia('POST', '/api/plataforma/empresas', { empresa: 'X', email: 'x@x.com', clave: 'clave-segura-1' })).estado, 403)
        admin = llamar(await cuenta(`admin-${sufijoAdmin}@api.test`))
        assert.deepEqual((await admin('GET', '/api/plataforma/yo')).datos, { admin: true })
    })

    test('el alta crea la cuenta del dueño y su empresa; el dueño puede entrar', async () => {
        const email = `nuevo-duenio-${sufijo}@api.test`
        const r = await admin('POST', '/api/plataforma/empresas', { empresa: 'Salón Nuevo API', nombre: 'Dueño Nuevo', email, clave: 'clave-inicial-1' })
        assert.equal(r.estado, 201)
        assert.equal(r.datos.cuenta_nueva, true)
        const empresas = (await admin('GET', '/api/plataforma/empresas')).datos
        assert.equal(empresas.find((e) => e.id === r.datos.organizacion_id).duenio.email, email)
        const duenio = llamar(await ingresar(email, 'clave-inicial-1'))
        const orgs = (await duenio('GET', '/api/organizaciones')).datos
        assert.equal(orgs[0].nombre, 'Salón Nuevo API')
        assert.equal((await duenio('GET', `/api/organizaciones/${orgs[0].id}/contexto`)).datos.rol, 'Propietario')
        // Repetir el alta con el mismo email no duplica la cuenta: le suma otra empresa
        const r2 = await admin('POST', '/api/plataforma/empresas', { empresa: 'Segunda Sede', email })
        assert.equal(r2.datos.cuenta_nueva, false)
    })

    test('un invitado crea su cuenta solo con una invitación válida', async () => {
        const roles = (await duenia('GET', `/api/organizaciones/${org}/roles`)).datos
        const email = `invitado-${sufijo}@api.test`
        const inv = await duenia('POST', `/api/organizaciones/${org}/invitaciones`, { email, rol_id: roles.find((r) => r.clave === 'recepcion').id })
        const token = inv.datos.token
        assert.equal((await llamar(null)('POST', `/api/invitaciones/token-falso/cuenta`, { nombre: 'X', clave: 'clave-segura-1' })).estado, 400)
        assert.equal((await llamar(null)('POST', `/api/invitaciones/${token}/cuenta`, { nombre: 'Invitado', clave: 'corta' })).estado, 400)
        const r = await llamar(null)('POST', `/api/invitaciones/${token}/cuenta`, { nombre: 'Invitado', clave: 'clave-segura-1', email: 'otro@x.com' })
        assert.equal(r.estado, 201)
        assert.equal(r.datos.email, email)  // siempre el email de la invitación
        assert.equal((await llamar(null)('POST', `/api/invitaciones/${token}/cuenta`, { nombre: 'Invitado', clave: 'clave-segura-1' })).estado, 409)
        const invitado = llamar(await ingresar(email, 'clave-segura-1'))
        assert.equal((await invitado('POST', `/api/invitaciones/${token}/aceptar`)).datos.organizacion_id, org)
    })
})
