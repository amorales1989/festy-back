-- Pruebas: capa de stored procedures (esquema api) que usa la API Node.
-- Se ejecutan como lo hace la API: rol authenticated + request.jwt.claims.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(37);

insert into auth.users (id, email, aud, role) values
  ('dddddddd-0000-0000-0000-000000000001', 'duenia@api.test', 'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-000000000002', 'intruso@api.test', 'authenticated', 'authenticated');

create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.rol(r text) returns void language sql as $$
  select set_config('role', r, true), set_config('request.jwt.claims', json_build_object('role', r)::text, true);
$$;
create function pg_temp.admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated, anon, service_role;

-- Privilegios del esquema
select pg_temp.rol('anon');
select throws_ok($$select api.sp_organizaciones_listar()$$, '42501', null, 'anon no ejecuta SP de datos');
select lives_ok($$select api.sp_invitacion_ver('no-existe')$$, 'anon puede ver una invitación por token');
select pg_temp.como('dddddddd-0000-0000-0000-000000000001');
select throws_ok($$select api.sp_push_pendientes(10)$$, '42501', null, 'un usuario no lee la cola de push');
select pg_temp.rol('service_role');
select lives_ok($$select api.sp_push_pendientes(10)$$, 'service_role lee la cola de push');

-- Alta de organización y sedes por SP
select pg_temp.como('dddddddd-0000-0000-0000-000000000001');
insert into k select 'org', api.sp_organizacion_crear('Salón API', 'America/Argentina/Buenos_Aires');
insert into k select 'sal', (api.sp_salon_guardar((select id from k where clave='org'), null, '{"nombre":"Marca"}')->>'id')::uuid;
insert into k select 'suc', (api.sp_sucursal_guardar((select id from k where clave='org'), null,
  jsonb_build_object('salon_id', (select id from k where clave='sal'), 'nombre', 'Centro'))->>'id')::uuid;
insert into k select 'esp', (api.sp_espacio_guardar((select id from k where clave='org'), null,
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'nombre', 'Salón principal', 'capacidad_maxima', 150), null)->>'id')::uuid;
select is(jsonb_array_length(api.sp_organizaciones_listar()), 1, 'lista sus organizaciones');
select ok(api.sp_organizacion_contexto((select id from k where clave='org'))->'permisos' ? 'reservas.crear', 'el contexto trae los permisos del rol');
select is(jsonb_array_length(api.sp_organizacion_contexto((select id from k where clave='org'))->'espacios'), 1, 'el contexto trae los espacios');
select is((select plan_clave || '/' || suscripcion_estado || '/' || coalesce(prueba_hasta::text, 'sin prueba')
            from public.organizaciones where id = (select id from k where clave='org')),
  'festy/activa/sin prueba', 'plan único: la organización nueva queda activa y sin período de prueba');
select is((select count(*)::int from public.rol_permisos where organizacion_id = (select id from k where clave='org') and permiso = 'plan.gestionar'),
  0, 'no existe el permiso de cambiar de plan');

-- Alta simple de un salón: crea la sede y su espacio principal
insert into k select 'rapido', (api.sp_salon_crear((select id from k where clave='org'), '{"nombre":"Quinta Norte","direccion":"Ruta 8 km 50","capacidad_maxima":220}')->>'espacio_id')::uuid;
select is((select e.nombre || '/' || e.capacidad_maxima || '/' || su.nombre from public.espacios e join public.sucursales su on su.id = e.sucursal_id
            where e.id = (select id from k where clave='rapido')), 'Quinta Norte/220/Quinta Norte', 'el salón nuevo queda con su espacio principal');
select is((select count(*)::int from public.salones where organizacion_id = (select id from k where clave='org')), 1, 'reutiliza la marca existente');
select throws_ok(format($$select api.sp_salon_crear(%L, '{"nombre":"Sin capacidad"}')$$, (select id from k where clave='org')), '23514', null,
  'pide la capacidad');

-- Clientes
insert into k select 'cli', (api.sp_cliente_guardar((select id from k where clave='org'), null,
  '{"nombre":" Marta Gómez ","email":"MARTA@MAIL.COM","telefono":"1155550000"}')->>'id')::uuid;
select is((select email from public.clientes where id = (select id from k where clave='cli')), 'marta@mail.com', 'normaliza el email');
select is((api.sp_clientes_listar((select id from k where clave='org'), 'marta', 20, 0)->>'total')::int, 1, 'busca clientes por nombre');

-- Reservas, agenda y disponibilidad
insert into k select 'res', api.sp_reserva_guardar((select id from k where clave='org'), null,
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'cliente_id', (select id from k where clave='cli'),
                     'titulo', 'Cumple 15 Sofía', 'estado', 'confirmada', 'inicio', '2027-05-08 21:00-03', 'fin', '2027-05-09 04:00-03',
                     'invitados', 120, 'precio_total', 1000000),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from k where clave='esp'))));
select is((api.sp_reservas_listar((select id from k where clave='org'), '{"estado":""}', 50, 0)->>'total')::int, 1, 'lista reservas');
select is(api.sp_reservas_listar((select id from k where clave='org'), '{"estado":"","texto":"#1"}', 50, 0)->'filas'->0->>'titulo',
  'Cumple 15 Sofía', 'busca por número');
select is(api.sp_reserva_obtener((select id from k where clave='res'))->'clientes'->>'nombre', 'Marta Gómez', 'obtiene la reserva con su cliente');
select is(jsonb_array_length(api.sp_agenda((select id from k where clave='org'), '2027-05-01', '2027-06-01', '2027-05-01', '2027-05-31')->'reservas'),
  1, 'la agenda trae la reserva del mes');
select is(jsonb_typeof(api.sp_disponibilidad((select id from k where clave='org'), array[(select id from k where clave='esp')],
  '2027-05-08 22:00-03', '2027-05-09 02:00-03')), 'object', 'consulta disponibilidad');
select throws_ok(format($$select api.sp_reserva_guardar(%L, null, %L::jsonb, %L::jsonb)$$, (select id from k where clave='org'),
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'cliente_id', (select id from k where clave='cli'), 'titulo', 'Pisada', 'estado', 'confirmada',
                     'inicio', '2027-05-08 23:00-03', 'fin', '2027-05-09 03:00-03'),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from k where clave='esp')))), '23P01', null, 'la superposición se rechaza en la base');

-- Cobros y comprobante
insert into k select 'pago', api.sp_pago_registrar((select id from k where clave='res'),
  jsonb_build_object('monto', 300000, 'fecha', '2027-01-10', 'medio', 'transferencia', 'concepto', 'sena'));
select is((api.sp_reserva_ficha((select id from k where clave='res'))->'saldo'->>'saldo')::numeric, 700000::numeric, 'la ficha calcula el saldo');
select is(api.sp_comprobante((select id from k where clave='pago'))->>'medio', 'transferencia', 'el comprobante trae el pago');
select is(jsonb_array_length(api.sp_cobros_listar((select id from k where clave='org'), '2027-01-01', '2027-01-31')), 1, 'lista cobros del rango');

-- Tareas, gastos y catálogo
select api.sp_tarea_guardar((select id from k where clave='org'), null, jsonb_build_object('titulo', 'Llamar a Marta', 'reserva_id', (select id from k where clave='res')));
select is(api.sp_tareas_listar((select id from k where clave='org'), 'todas', 'abiertas')->0->'reservas'->>'titulo', 'Cumple 15 Sofía', 'tareas con su evento');
select api.sp_gasto_guardar((select id from k where clave='org'), null, '{"fecha":"2027-01-15","descripcion":"Limpieza","monto":50000}');
select is(jsonb_array_length(api.sp_gastos_listar((select id from k where clave='org'), '2027-01-01', '2027-01-31')), 1, 'lista gastos');
select api.sp_servicio_guardar((select id from k where clave='org'), null, '{"nombre":"DJ","precio":400000}');
select is(api.sp_servicios_listar((select id from k where clave='org'), true)->0->>'nombre', 'DJ', 'lista el catálogo');

-- Borrado genérico solo sobre tablas permitidas
select throws_ok($$select api.sp_eliminar('perfiles', gen_random_uuid())$$, '22023', null, 'sp_eliminar rechaza tablas fuera de la lista');
select throws_ok($$select api.sp_eliminar('clientes', gen_random_uuid())$$, '42501', null, 'sp_eliminar avisa si no borró nada');

-- Aislamiento: otra cuenta no ve ni toca nada de esta organización
select pg_temp.como('dddddddd-0000-0000-0000-000000000002');
select is(jsonb_array_length(api.sp_organizaciones_listar()), 0, 'el intruso no ve la organización');
select is((api.sp_reservas_listar((select id from k where clave='org'), '{"estado":""}', 50, 0)->>'total')::int, 0, 'el intruso no ve reservas');
select throws_ok(format($$select api.sp_reserva_obtener(%L)$$, (select id from k where clave='res')), 'P0002', null, 'el intruso no obtiene la reserva');
select throws_ok(format($$select api.sp_eliminar('reservas', %L)$$, (select id from k where clave='res')), '42501', null, 'el intruso no borra la reserva');
select throws_ok(format($$select api.sp_pago_registrar(%L, '{"monto":1,"fecha":"2027-01-10","medio":"efectivo","concepto":"cuota"}')$$,
  (select id from k where clave='res')), null, null, 'el intruso no registra cobros');
select is(api.sp_exportar((select id from k where clave='org'))->'clientes', 'null'::jsonb, 'el intruso no exporta clientes');

-- Cuenta de demostración: no se le cambia la contraseña ni el email
select pg_temp.admin();
insert into auth.users (id, email, aud, role, encrypted_password, raw_app_meta_data) values
  ('dddddddd-0000-0000-0000-0000000000de', 'demo@api.test', 'authenticated', 'authenticated', 'hash-original', '{"demo": true}');
select throws_ok($$update auth.users set encrypted_password = 'otro-hash' where id = 'dddddddd-0000-0000-0000-0000000000de'$$,
  '42501', null, 'la cuenta demo no cambia su contraseña');
select throws_ok($$update auth.users set email = 'robada@api.test' where id = 'dddddddd-0000-0000-0000-0000000000de'$$,
  '42501', null, 'la cuenta demo no cambia su email');
select lives_ok($$update auth.users set encrypted_password = 'otro-hash' where id = 'dddddddd-0000-0000-0000-000000000001'$$,
  'una cuenta normal sí cambia su contraseña');

select * from finish();
rollback;
