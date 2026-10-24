-- Pruebas: catálogo, presupuestos, entrevistas, comprobantes y notificaciones.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(28);

insert into auth.users (id, email, aud, role) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'duenia@ventas.test', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'finanzas@ventas.test', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'operativo@ventas.test', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'otra@ventas.test', 'authenticated', 'authenticated');

create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated;

select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000001');
insert into k select 'org', public.crear_organizacion('Salón Ventas');
with s as (insert into public.salones (organizacion_id, nombre) select id, 'Marca' from k where clave = 'org' returning id, organizacion_id),
     su as (insert into public.sucursales (organizacion_id, salon_id, nombre) select organizacion_id, id, 'Centro' from s returning id, organizacion_id),
     e as (insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima) select organizacion_id, id, 'Salón', 200 from su returning id)
insert into k select 'esp', id from e;
with c as (insert into public.clientes (organizacion_id, nombre, telefono) select id, 'Sofía Paz', '351' from k where clave = 'org' returning id)
insert into k select 'cli', id from c;

select pg_temp.admin();
insert into public.membresias (organizacion_id, usuario_id, rol_id)
select (select id from k where clave='org'), u, (select id from public.roles where organizacion_id = (select id from k where clave='org') and clave = r)
from (values ('bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'finanzas'), ('bbbbbbbb-0000-0000-0000-000000000003'::uuid, 'operativo')) t(u, r);

-- Catálogo
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000001');
with s as (insert into public.servicios (organizacion_id, nombre, tipo, unidad, precio)
  select id, 'Menú completo', 'servicio', 'persona', 25000 from k where clave = 'org' returning id)
insert into k select 'menu', id from s;
select is((select count(*)::int from public.servicios), 1, 'la propietaria crea servicios');
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000003');
select is((select count(*)::int from public.servicios), 0, 'operativo no ve el catálogo');
select throws_ok(format($$insert into public.servicios (organizacion_id, nombre, precio) values (%L, 'X servicio', 1)$$, (select id from k where clave='org')),
  '42501', null, 'operativo no puede crear servicios');
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000004');
select is((select count(*)::int from public.servicios), 0, 'otra organización no ve el catálogo');

-- Presupuesto: numeración, ítems y total
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000001');
with p as (insert into public.presupuestos (organizacion_id, cliente_id, titulo, tipo_evento, fecha_evento, hora_inicio, hora_fin, espacio_id, invitados, descuento, sena_porcentaje, cantidad_cuotas)
  select (select id from k where clave='org'), (select id from k where clave='cli'), 'Los 15 de Sofía', 'quince', '2027-09-18', '21:30', '05:30',
         (select id from k where clave='esp'), 150, 0, 30, 3 returning id)
insert into k select 'pre', id from p;
select is((select numero from public.presupuestos where id = (select id from k where clave='pre')), 1, 'numeración correlativa de presupuestos');
select ok((select valido_hasta > current_date and condiciones is not null from public.presupuestos where id = (select id from k where clave='pre')),
  'vigencia y condiciones por defecto');
insert into public.presupuesto_items (organizacion_id, presupuesto_id, servicio_id, descripcion, cantidad, unidad, precio_unitario) values
  ((select id from k where clave='org'), (select id from k where clave='pre'), (select id from k where clave='menu'), 'Menú completo', 150, 'persona', 25000),
  ((select id from k where clave='org'), (select id from k where clave='pre'), null, 'Alquiler del salón', 1, 'evento', 1250000);
select is((select subtotal from public.presupuestos where id = (select id from k where clave='pre')), 5000000.00, 'el subtotal suma los ítems');
update public.presupuestos set descuento = 200000 where id = (select id from k where clave='pre');
select is((select total from public.presupuestos where id = (select id from k where clave='pre')), 4800000.00, 'el total descuenta');
select throws_ok(format($$update public.organizaciones set ultimo_numero_presupuesto = 99 where id = %L$$, (select id from k where clave='org')),
  '42501', null, 'el contador de presupuestos no se puede manipular');

-- Aceptar → evento + cuotas
insert into k select 'res', public.aceptar_presupuesto((select id from k where clave='pre'), 'tentativa');
select is((select estado::text from public.reservas where id = (select id from k where clave='res')), 'tentativa', 'aceptar crea el evento con el estado elegido');
select is((select precio_total from public.reservas where id = (select id from k where clave='res')), 4800000.00, 'el evento toma el total del presupuesto');
select is((select count(*)::int from public.cuotas where reserva_id = (select id from k where clave='res')), 4, 'seña + 3 cuotas');
select is((select sum(monto) from public.cuotas where reserva_id = (select id from k where clave='res')), 4800000.00, 'las cuotas suman el total');
select is((select monto from public.cuotas where reserva_id = (select id from k where clave='res') and concepto = 'Seña'), 1440000.00, 'seña del 30 %');
select is((select estado from public.presupuestos where id = (select id from k where clave='pre')), 'aceptado', 'el presupuesto queda aceptado');
select throws_like(format($$select public.aceptar_presupuesto(%L)$$, (select id from k where clave='pre')), '%ya fue aceptado%', 'no se acepta dos veces');

-- Otro presupuesto para la misma fecha: al aceptarlo, la agenda lo rechaza
with p as (insert into public.presupuestos (organizacion_id, cliente_id, titulo, fecha_evento, hora_inicio, hora_fin, espacio_id)
  select (select id from k where clave='org'), (select id from k where clave='cli'), 'Otro evento', '2027-09-18', '22:00', '02:00', (select id from k where clave='esp') returning id)
insert into k select 'pre2', id from p;
select throws_like(format($$select public.aceptar_presupuesto(%L, 'confirmada')$$, (select id from k where clave='pre2')), '%ya está ocupado%',
  'aceptar un presupuesto sobre una fecha ocupada falla');

-- Comprobantes y notificaciones
insert into k select 'pago1', public.registrar_pago((select id from k where clave='res'), 1440000, current_date, 'transferencia', 'sena');
insert into k select 'pago2', public.registrar_pago((select id from k where clave='res'), 500000, current_date, 'efectivo', 'cuota');
select is((select array_agg(numero_comprobante order by numero_comprobante) from public.pagos where reserva_id = (select id from k where clave='res')),
  array[1, 2], 'los comprobantes se numeran correlativamente');
select throws_like(format($$update public.pagos set numero_comprobante = 7 where id = %L$$, (select id from k where clave='pago1')),
  '%no se puede modificar%', 'el número de comprobante no se puede cambiar');
select pg_temp.admin();
select is((select count(*)::int from public.notificaciones where usuario_id = 'bbbbbbbb-0000-0000-0000-000000000002' and tipo = 'pago'), 2,
  'finanzas recibe aviso de cada cobro');
select is((select count(*)::int from public.notificaciones where usuario_id = 'bbbbbbbb-0000-0000-0000-000000000001' and tipo = 'pago'), 0,
  'quien registra el cobro no se notifica a sí misma');
select ok((select cuerpo like '%Seña · #1 Los 15 de Sofía%' and titulo = 'Cobro registrado: $ 1.440.000,00'
           from public.notificaciones where usuario_id = 'bbbbbbbb-0000-0000-0000-000000000002' order by id limit 1),
  'texto de la notificación en formato argentino');

-- Las notificaciones son privadas
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000003');
select is((select count(*)::int from public.notificaciones), 0, 'cada usuario ve solo sus notificaciones');
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000002');
update public.notificaciones set leida_at = now();
select is((select count(*)::int from public.notificaciones where leida_at is null), 0, 'puede marcarlas como leídas');
select throws_ok($$update public.notificaciones set titulo = 'hack'$$, '42501', null, 'no puede cambiar su contenido');

-- Dispositivos
select lives_ok($$select public.registrar_dispositivo('token-de-prueba-0123456789', 'android')$$, 'registra su dispositivo');
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000003');
select public.registrar_dispositivo('token-de-prueba-0123456789', 'android');
select pg_temp.admin();
select is((select usuario_id from public.dispositivos where token = 'token-de-prueba-0123456789'), 'bbbbbbbb-0000-0000-0000-000000000003'::uuid,
  'si otro usuario inicia sesión en el mismo teléfono, el token pasa a él');

-- Entrevistas: operativo no las ve
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000001');
insert into public.entrevistas (organizacion_id, contacto_nombre, contacto_telefono, inicio, asignada_a)
values ((select id from k where clave='org'), 'Marcela Ruiz', '351 222', now() + interval '2 days', 'bbbbbbbb-0000-0000-0000-000000000002');
select pg_temp.como('bbbbbbbb-0000-0000-0000-000000000003');
select is((select count(*)::int from public.entrevistas), 0, 'operativo no ve entrevistas');

select * from finish();
rollback;
