-- Pruebas: caja por cuenta, proveedores y rentabilidad, página pública con pedido de fecha.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(32);

insert into auth.users (id, email, aud, role) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'duenia@caja.test', 'authenticated', 'authenticated'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'operativo@caja.test', 'authenticated', 'authenticated');

create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.anonimo() returns void language sql as $$
  select set_config('role', 'anon', true), set_config('request.jwt.claims', '{"role":"anon"}', true);
$$;
create function pg_temp.admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated, anon;

-- Preparación: organización, espacio, cliente y evento de $ 1.000.000
select pg_temp.como('eeeeeeee-0000-0000-0000-000000000001');
insert into k select 'org', api.sp_organizacion_crear('Salón Caja', 'America/Argentina/Buenos_Aires');
insert into k select 'sal', (api.sp_salon_guardar((select id from k where clave='org'), null, '{"nombre":"Marca"}')->>'id')::uuid;
insert into k select 'suc', (api.sp_sucursal_guardar((select id from k where clave='org'), null,
  jsonb_build_object('salon_id', (select id from k where clave='sal'), 'nombre', 'Centro'))->>'id')::uuid;
insert into k select 'esp', (api.sp_espacio_guardar((select id from k where clave='org'), null,
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'nombre', 'Salón grande', 'capacidad_maxima', 200), null)->>'id')::uuid;
insert into k select 'cli', (api.sp_cliente_guardar((select id from k where clave='org'), null, '{"nombre":"Ana Díaz","telefono":"1144440000"}')->>'id')::uuid;
insert into k select 'res', api.sp_reserva_guardar((select id from k where clave='org'), null,
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'cliente_id', (select id from k where clave='cli'), 'titulo', 'Boda Díaz',
                     'estado', 'confirmada', 'inicio', '2027-06-12 21:00-03', 'fin', '2027-06-13 04:00-03', 'precio_total', 1000000),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from k where clave='esp'))));
insert into k select 'banco', id from public.cuentas where organizacion_id = (select id from k where clave='org') and nombre = 'Banco';
insert into k select 'efectivo', id from public.cuentas where organizacion_id = (select id from k where clave='org') and nombre = 'Efectivo';
insert into k select 'mp', id from public.cuentas where organizacion_id = (select id from k where clave='org') and nombre = 'Mercado Pago';

-- ---------------------------------------------------------------------------
-- Caja
-- ---------------------------------------------------------------------------
select is(jsonb_array_length(api.sp_cuentas_listar((select id from k where clave='org'))), 3, 'la organización nace con 3 cuentas');
insert into k select 'pago1', api.sp_pago_registrar((select id from k where clave='res'),
  '{"monto":300000,"fecha":"2027-01-10","medio":"transferencia","concepto":"sena"}');
select is((select cuenta_id from public.pagos where id = (select id from k where clave='pago1')), (select id from k where clave='banco'),
  'una transferencia va a la cuenta Banco');
insert into k select 'pago2', api.sp_pago_registrar((select id from k where clave='res'),
  jsonb_build_object('monto', 100000, 'fecha', '2027-01-11', 'medio', 'efectivo', 'concepto', 'cuota', 'cuenta_id', (select id from k where clave='mp')));
select is((select cuenta_id from public.pagos where id = (select id from k where clave='pago2')), (select id from k where clave='mp'),
  'se respeta la cuenta elegida');
select throws_ok(format($$update public.pagos set cuenta_id = %L where id = %L$$, (select id from k where clave='efectivo'), (select id from k where clave='pago1')),
  '42501', null, 'la cuenta de un cobro no se cambia después');
select api.sp_gasto_guardar((select id from k where clave='org'), null, '{"fecha":"2027-01-12","descripcion":"Limpieza","monto":50000,"medio":"efectivo"}');
select lives_ok(format($$select api.sp_transferencia_crear(%L, %L::jsonb)$$, (select id from k where clave='org'),
  jsonb_build_object('fecha', '2027-01-13', 'desde_cuenta_id', (select id from k where clave='banco'), 'hacia_cuenta_id', (select id from k where clave='efectivo'), 'monto', 20000)),
  'transferencia entre cuentas');
select is((select (c->>'saldo')::numeric from jsonb_array_elements(api.sp_caja((select id from k where clave='org'), '2027-01-01', '2027-12-31')->'cuentas') c
            where c->>'nombre' = 'Banco'), 280000::numeric, 'saldo Banco = 300.000 − 20.000');
select is((select (c->>'saldo')::numeric from jsonb_array_elements(api.sp_caja((select id from k where clave='org'), '2027-01-01', '2027-12-31')->'cuentas') c
            where c->>'nombre' = 'Efectivo'), -30000::numeric, 'saldo Efectivo = −50.000 + 20.000');
select is((api.sp_caja((select id from k where clave='org'), '2027-01-01', '2027-12-31')->'periodo'->>'cobros')::numeric, 400000::numeric, 'cobros del período');
select throws_ok(format($$select api.sp_cuenta_guardar(%L, null, '{"nombre":"Caja chica","medios":["efectivo"]}')$$, (select id from k where clave='org')),
  '23514', null, 'un medio no puede ir a dos cuentas activas');
select lives_ok(format($$select api.sp_cuenta_guardar(%L, null, '{"nombre":"Caja chica","tipo":"efectivo","saldo_inicial":5000}')$$, (select id from k where clave='org')),
  'se agrega una cuenta sin medios asociados');

-- ---------------------------------------------------------------------------
-- Proveedores y rentabilidad
-- ---------------------------------------------------------------------------
insert into k select 'prov', (api.sp_proveedor_guardar((select id from k where clave='org'), null, '{"nombre":"Catering Sur","rubro":"Catering"}')->>'id')::uuid;
insert into k select 'costo', api.sp_costo_guardar((select id from k where clave='org'), null,
  jsonb_build_object('reserva_id', (select id from k where clave='res'), 'proveedor_id', (select id from k where clave='prov'), 'descripcion', 'Catering', 'monto', 400000));
insert into k select 'gpago', api.sp_costo_pagar((select id from k where clave='costo'), '{"fecha":"2027-02-01","monto":150000,"medio":"transferencia"}');
select is((select categoria || '/' || reserva_id::text || '/' || costo_id::text from public.gastos where id = (select id from k where clave='gpago')),
  'proveedores/' || (select id from k where clave='res') || '/' || (select id from k where clave='costo'), 'pagar un costo registra el gasto del evento');
select is((select cuenta_id from public.gastos where id = (select id from k where clave='gpago')), (select id from k where clave='banco'), 'el pago al proveedor sale de la cuenta');
select throws_ok(format($$select api.sp_costo_pagar(%L, '{"fecha":"2027-02-02","monto":300000,"medio":"efectivo"}')$$, (select id from k where clave='costo')),
  '23514', null, 'no se paga más de lo que falta');
select throws_ok(format($$select api.sp_costo_guardar(%L, %L, %L::jsonb)$$, (select id from k where clave='org'), (select id from k where clave='costo'),
  jsonb_build_object('reserva_id', (select id from k where clave='res'), 'descripcion', 'Catering', 'monto', 100000)),
  '23514', null, 'el costo no baja de lo ya pagado');
select is((api.sp_costos_evento((select id from k where clave='res'))->'costos'->0->>'pendiente')::numeric, 250000::numeric, 'pendiente de pago del costo');
select is((api.sp_costos_evento((select id from k where clave='res'))->>'ganancia')::numeric, 600000::numeric, 'ganancia del evento = 1.000.000 − 400.000');
select is((api.sp_rentabilidad((select id from k where clave='org'), '2027-06-01', '2027-06-30')->'totales'->>'margen')::numeric, 60.0::numeric, 'margen del período');
select is((api.sp_proveedores_listar((select id from k where clave='org'))->0->>'pagado')::numeric, 150000::numeric, 'lo pagado a cada proveedor');

-- Permisos: el personal operativo no ve caja, costos ni rentabilidad
select pg_temp.admin();
insert into public.membresias (organizacion_id, usuario_id, rol_id)
select (select id from k where clave='org'), 'eeeeeeee-0000-0000-0000-000000000002',
       (select id from public.roles where organizacion_id = (select id from k where clave='org') and clave = 'operativo');
select pg_temp.como('eeeeeeee-0000-0000-0000-000000000002');
select throws_ok(format($$select api.sp_caja(%L, '2027-01-01', '2027-12-31')$$, (select id from k where clave='org')), '42501', null, 'operativo no ve la caja');
select throws_ok(format($$select api.sp_rentabilidad(%L, '2027-01-01', '2027-12-31')$$, (select id from k where clave='org')), '42501', null, 'operativo no ve rentabilidad');
select is(jsonb_array_length(api.sp_costos_evento((select id from k where clave='res'))->'costos'), 0, 'operativo no ve costos');
select throws_ok(format($$select api.sp_costo_pagar(%L, '{"fecha":"2027-02-02","monto":1000,"medio":"efectivo"}')$$, (select id from k where clave='costo')),
  'P0002', null, 'operativo no paga proveedores');

-- ---------------------------------------------------------------------------
-- Página pública
-- ---------------------------------------------------------------------------
select pg_temp.anonimo();
select throws_ok($$select api.sp_publico_salon('salon-caja')$$, 'P0002', null, 'una página no publicada no existe');
select pg_temp.como('eeeeeeee-0000-0000-0000-000000000001');
select is(api.sp_pagina_guardar((select id from k where clave='org'),
  '{"pagina_slug":"Salon-Caja","pagina_activa":true,"pagina_descripcion":"El mejor salón","pagina_whatsapp":"+54 9 11 5555-0000"}')->>'pagina_whatsapp',
  '5491155550000', 'se publica la página (WhatsApp solo dígitos)');
select pg_temp.anonimo();
select is(api.sp_publico_salon('salon-caja')->>'nombre', 'Salón Caja', 'el visitante ve el salón');
select is(jsonb_array_length(api.sp_publico_salon('salon-caja')->'espacios'), 1, 'y sus espacios');
select is(api.sp_publico_ocupacion('salon-caja', '2027-06-01', '2027-06-30'),
  jsonb_build_array(jsonb_build_object('fecha', '2027-06-12', 'espacio_id', (select id from k where clave='esp'))),
  'solo ve qué día está ocupado (la madrugada no ocupa el día siguiente)');
select throws_ok($$select api.sp_caja(gen_random_uuid(), '2027-01-01', '2027-01-31')$$, '42501', null, 'el visitante no accede a datos privados');
select is((api.sp_publico_pedido('salon-caja', jsonb_build_object('nombre', 'Lucas Pérez', 'telefono', '11 6666-7777', 'fecha', '2027-08-20',
  'espacio_id', (select id from k where clave='esp'), 'tipo_evento', 'cumpleanos', 'invitados', 80, 'mensaje', 'Somos 80')))->>'ok', 'true', 'pedido de fecha enviado');
select throws_ok(format($$select api.sp_publico_pedido('salon-caja', %L::jsonb)$$,
  jsonb_build_object('nombre', 'X', 'telefono', '123', 'fecha', '2027-08-20', 'espacio_id', (select id from k where clave='esp'))),
  '23514', null, 'se validan los datos del pedido');
select pg_temp.admin();
select is((select r.estado::text || '/' || c.origen from public.reservas r join public.clientes c on c.id = r.cliente_id
            where r.organizacion_id = (select id from k where clave='org') and c.nombre = 'Lucas Pérez'), 'consulta/web',
  'el pedido crea una consulta (no bloquea la fecha) y un cliente de origen web');
select ok(exists (select 1 from public.notificaciones where usuario_id = 'eeeeeeee-0000-0000-0000-000000000001' and tipo = 'pedido_web'),
  'el equipo recibe el aviso del pedido');

select * from finish();
rollback;
