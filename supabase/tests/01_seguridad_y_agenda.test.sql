-- Pruebas de base de datos (pgTAP). Ejecutar con: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(54);

-- ---------------------------------------------------------------------------
-- Usuarios de prueba
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data, aud, role) values
  ('11111111-1111-1111-1111-111111111111', 'duenia@a.test',     '{"nombre":"Dueña A"}', 'authenticated', 'authenticated'),
  ('22222222-2222-2222-2222-222222222222', 'duenio@b.test',     '{"nombre":"Dueño B"}', 'authenticated', 'authenticated'),
  ('33333333-3333-3333-3333-333333333333', 'operativo@a.test',  '{"nombre":"Operativo A"}', 'authenticated', 'authenticated'),
  ('44444444-4444-4444-4444-444444444444', 'finanzas@a.test',   '{"nombre":"Finanzas A"}', 'authenticated', 'authenticated');

create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.como_admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;

select ok((select count(*) from public.perfiles where email like '%@a.test' or email like '%@b.test') = 4, 'se crea un perfil por usuario');

-- ---------------------------------------------------------------------------
-- Alta de organizaciones
-- ---------------------------------------------------------------------------
select pg_temp.como('11111111-1111-1111-1111-111111111111');
create temp table ids (clave text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
insert into ids select 'orgA', public.crear_organizacion('Salón A');
select ok((select count(*) from public.roles where organizacion_id = (select id from ids where clave='orgA')) = 7,
          'se crean los 7 roles de sistema');
select ok(public.tiene_permiso((select id from ids where clave='orgA'), 'organizacion.eliminar'), 'la creadora es propietaria');

select pg_temp.como('22222222-2222-2222-2222-222222222222');
insert into ids select 'orgB', public.crear_organizacion('Salón B');

-- ---------------------------------------------------------------------------
-- Sedes de A
-- ---------------------------------------------------------------------------
select pg_temp.como('11111111-1111-1111-1111-111111111111');
with x as (insert into public.salones (organizacion_id, nombre)
  values ((select id from ids where clave='orgA'), 'Marca A') returning id)
insert into ids select 'salonA', id from x;
with x as (insert into public.sucursales (organizacion_id, salon_id, nombre)
  values ((select id from ids where clave='orgA'), (select id from ids where clave='salonA'), 'Centro') returning id)
insert into ids select 'sucA', id from x;
with x as (insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima, montaje_min, desmontaje_min, limpieza_min, preparacion_min)
  values ((select id from ids where clave='orgA'), (select id from ids where clave='sucA'), 'Salón grande', 100, 60, 30, 30, 0) returning id)
insert into ids select 'espA1', id from x;
with x as (insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima)
  values ((select id from ids where clave='orgA'), (select id from ids where clave='sucA'), 'Quincho', 30) returning id)
insert into ids select 'espA2', id from x;
with x as (insert into public.clientes (organizacion_id, nombre, telefono)
  values ((select id from ids where clave='orgA'), 'Ana Pérez', '351 555 0000') returning id)
insert into ids select 'cliA', id from x;

-- ---------------------------------------------------------------------------
-- Aislamiento entre organizaciones
-- ---------------------------------------------------------------------------
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.organizaciones), 1, 'B solo ve su organización');
select is((select count(*)::int from public.clientes), 0, 'B no ve clientes de A');
select is((select count(*)::int from public.espacios), 0, 'B no ve espacios de A');
select throws_ok(
  format($$insert into public.clientes (organizacion_id, nombre) values (%L, 'Intruso')$$, (select id from ids where clave='orgA')),
  '42501', null, 'B no puede insertar clientes en A');
select throws_ok(
  format($$insert into public.salones (organizacion_id, nombre) values (%L, 'Intruso')$$, (select id from ids where clave='orgA')),
  '42501', null, 'B no puede crear salones en A');
update public.clientes set nombre = 'Hackeado' where id = (select id from ids where clave='cliA');
select pg_temp.como_admin();
select is((select nombre from public.clientes where id = (select id from ids where clave='cliA')), 'Ana Pérez', 'B no puede modificar clientes de A');

-- Clave foránea compuesta: no se puede referenciar un espacio de otra organización
select pg_temp.como('22222222-2222-2222-2222-222222222222');
with x as (insert into public.salones (organizacion_id, nombre)
  values ((select id from ids where clave='orgB'), 'Marca B') returning id)
insert into ids select 'salonB', id from x;
select throws_ok(
  format($$insert into public.sucursales (organizacion_id, salon_id, nombre) values (%L, %L, 'Cruce')$$,
         (select id from ids where clave='orgB'), (select id from ids where clave='salonA')),
  '23503', null, 'no se puede colgar una sucursal de un salón de otra organización');
select is(public.panel_resumen((select id from ids where clave='orgB'), current_date, current_date)->>'espacios_activos', '0',
          'el panel de B no cuenta espacios de A');
select throws_ok(
  format($$select public.panel_resumen(%L, current_date, current_date)$$, (select id from ids where clave='orgA')),
  '42501', null, 'B no puede pedir el panel de A');

-- ---------------------------------------------------------------------------
-- Superposición en agenda (garantizada por EXCLUDE)
-- ---------------------------------------------------------------------------
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into ids select 'res1', public.guardar_reserva(
  (select id from ids where clave='orgA'), null,
  jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                     'titulo', 'Casamiento', 'estado', 'confirmada', 'inicio', '2027-03-06 21:00-03', 'fin', '2027-03-07 05:00-03',
                     'invitados', 90),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1'))));
select is((select numero from public.reservas where id = (select id from ids where clave='res1')), 1, 'numeración correlativa por organización');
select is((select upper(rango) - lower(rango) from public.ocupaciones o join public.reserva_espacios re on re.id = o.reserva_espacio_id
           where re.reserva_id = (select id from ids where clave='res1')), interval '10 hours',
          'la ocupación suma 8 h de evento + montaje (60) + desmontaje y limpieza (60)');

select throws_like(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, %L::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'Choque', 'estado', 'confirmada', 'inicio', '2027-03-07 05:30-03', 'fin', '2027-03-07 08:00-03'),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1')))),
  '%ya está ocupado%', 'rechaza superposición con el tiempo de limpieza');

select lives_ok(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, %L::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'Brunch', 'estado', 'confirmada', 'inicio', '2027-03-07 07:00-03', 'fin', '2027-03-07 10:00-03'),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1')))),
  'acepta un evento que empieza al terminar la limpieza (montaje incluido)');

select lives_ok(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, %L::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'Otra en el quincho', 'estado', 'confirmada', 'inicio', '2027-03-06 21:00-03', 'fin', '2027-03-07 02:00-03'),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA2')))),
  'otro espacio en el mismo horario está permitido');

insert into ids select 'consulta', public.guardar_reserva(
  (select id from ids where clave='orgA'), null,
  jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                     'titulo', 'Consulta mismo día', 'estado', 'consulta', 'inicio', '2027-03-06 21:00-03', 'fin', '2027-03-07 04:00-03'),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1'))));
select ok(true, 'una consulta no bloquea la fecha');

select throws_like(
  format($$update public.reservas set estado = 'tentativa' where id = %L$$, (select id from ids where clave='consulta')),
  '%ya está ocupado%', 'pasar la consulta a tentativa sobre una fecha tomada falla');

select is(
  (public.verificar_disponibilidad((select id from ids where clave='orgA'), array[(select id from ids where clave='espA1')],
     '2027-03-06 22:00-03', '2027-03-06 23:00-03')->>'disponible'), 'false', 'verificar_disponibilidad informa el conflicto');

-- Bloqueos
select throws_like(
  format($$insert into public.bloqueos (organizacion_id, espacio_id, inicio, fin, tipo) values (%L, %L, '2027-03-06 10:00-03', '2027-03-06 22:00-03', 'mantenimiento')$$,
    (select id from ids where clave='orgA'), (select id from ids where clave='espA1')),
  '%ya está ocupado%', 'un bloqueo no puede pisar una reserva');
insert into public.bloqueos (organizacion_id, espacio_id, inicio, fin, tipo, motivo)
values ((select id from ids where clave='orgA'), (select id from ids where clave='espA1'), '2027-04-01 00:00-03', '2027-04-03 00:00-03', 'obra', 'Pintura');
select throws_like(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, %L::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'En obra', 'estado', 'tentativa', 'inicio', '2027-04-02 20:00-03', 'fin', '2027-04-02 23:00-03'),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1')))),
  '%bloqueo (Pintura)%', 'una reserva no puede pisar un bloqueo');

-- Cancelar libera la fecha
update public.reservas set estado = 'cancelada', motivo_cancelacion = 'Prueba' where id = (select id from ids where clave='res1');
select is((select bloqueante from public.ocupaciones o join public.reserva_espacios re on re.id = o.reserva_espacio_id
           where re.reserva_id = (select id from ids where clave='res1')), false, 'cancelar libera la agenda');
update public.reservas set estado = 'tentativa' where id = (select id from ids where clave='consulta');
select ok((select vence_tentativa_at is not null from public.reservas where id = (select id from ids where clave='consulta')),
          'la tentativa recibe fecha de vencimiento');

-- Vencimiento automático de tentativas
select pg_temp.como_admin();
update public.reservas set vence_tentativa_at = now() - interval '1 minute' where id = (select id from ids where clave='consulta');
select is(public.vencer_tentativas(), 1, 'vencer_tentativas libera la tentativa vencida');
select is((select estado::text from public.reservas where id = (select id from ids where clave='consulta')), 'consulta', 'vuelve a consulta');

-- Capacidad (validada al final de la transacción)
select pg_temp.como('11111111-1111-1111-1111-111111111111');
set constraints all immediate;
select throws_like(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, %L::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'Muy grande', 'estado', 'consulta', 'inicio', '2027-05-01 20:00-03', 'fin', '2027-05-02 02:00-03', 'invitados', 50),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA2')))),
  '%supera la capacidad%', 'rechaza más invitados que la capacidad');
set constraints all deferred;

-- ---------------------------------------------------------------------------
-- Roles y permisos
-- ---------------------------------------------------------------------------
select pg_temp.como_admin();
insert into public.membresias (organizacion_id, usuario_id, rol_id) values
  ((select id from ids where clave='orgA'), '33333333-3333-3333-3333-333333333333',
   (select id from public.roles where organizacion_id = (select id from ids where clave='orgA') and clave = 'operativo')),
  ((select id from ids where clave='orgA'), '44444444-4444-4444-4444-444444444444',
   (select id from public.roles where organizacion_id = (select id from ids where clave='orgA') and clave = 'finanzas'));
with x as (insert into public.tareas (organizacion_id, titulo, asignada_a)
  values ((select id from ids where clave='orgA'), 'Armar mesas', '33333333-3333-3333-3333-333333333333') returning id)
insert into ids select 'tareaOp', id from x;

select pg_temp.como('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.clientes), 0, 'operativo no ve clientes (sin clientes.ver)');
select ok((select count(*) from public.reservas) > 0, 'operativo ve reservas');
select is((select count(*)::int from public.pagos), 0, 'operativo no ve cobros');
select throws_ok(
  format($$select public.guardar_reserva(%L, null, %L::jsonb, '[]'::jsonb)$$,
    (select id from ids where clave='orgA'),
    jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                       'titulo', 'No debería', 'estado', 'consulta', 'inicio', '2027-06-01 20:00-03', 'fin', '2027-06-01 23:00-03')),
  '42501', null, 'operativo no puede crear reservas');
update public.tareas set estado = 'hecha' where id = (select id from ids where clave='tareaOp');
select is((select estado from public.tareas where id = (select id from ids where clave='tareaOp')), 'hecha', 'operativo completa su tarea');
select throws_ok(
  format($$update public.tareas set titulo = 'Otra cosa' where id = %L$$, (select id from ids where clave='tareaOp')),
  '42501', null, 'operativo no puede editar el contenido de la tarea');
select is(public.panel_resumen((select id from ids where clave='orgA'), current_date, current_date)->'ingresos', 'null'::jsonb,
          'el panel oculta ingresos a quien no tiene pagos.ver');
select is_empty(
  format($$update public.membresias set activo = false where usuario_id = '11111111-1111-1111-1111-111111111111' and organizacion_id = %L returning id$$,
         (select id from ids where clave='orgA')),
  'operativo no puede desactivar usuarios (RLS no le expone la fila)');
select pg_temp.como_admin();
select ok((select activo from public.membresias where usuario_id = '11111111-1111-1111-1111-111111111111'), 'la propietaria sigue activa');

-- Cobros
select pg_temp.como('44444444-4444-4444-4444-444444444444');
insert into ids select 'res2', id from public.reservas where titulo = 'Brunch';
select throws_ok(
  format($$update public.reservas set estado = 'consulta' where id = %L$$, (select id from ids where clave='res2')),
  '42501', null, 'finanzas (solo contratos) no puede cambiar el estado de una reserva');
insert into ids select 'pago1', public.registrar_pago((select id from ids where clave='res2'), 1000, current_date, 'efectivo', 'cuota');
select throws_like(
  format($$update public.pagos set monto = 5 where id = %L$$, (select id from ids where clave='pago1')),
  '%no se puede modificar%', 'un cobro no se puede editar');
select throws_like(
  format($$update public.pagos set anulado = true where id = %L$$, (select id from ids where clave='pago1')),
  '%motivo%', 'anular exige motivo');
update public.pagos set anulado = true, anulado_motivo = 'Error de carga' where id = (select id from ids where clave='pago1');
select ok((select anulado and anulado_por = '44444444-4444-4444-4444-444444444444' from public.pagos where id = (select id from ids where clave='pago1')),
          'anulación registrada con usuario');
delete from public.pagos where id = (select id from ids where clave='pago1');
select ok(exists (select 1 from public.pagos where id = (select id from ids where clave='pago1')), 'los cobros no se pueden borrar');

-- Finanzas registra una seña: la RPC cambia el estado aunque el rol no edite reservas
insert into ids select 'res4', id from public.reservas where titulo = 'Otra en el quincho';
select pg_temp.como_admin();
update public.reservas set estado = 'consulta' where id = (select id from ids where clave='res4');
select pg_temp.como('44444444-4444-4444-4444-444444444444');
select lives_ok(format($$select public.registrar_pago(%L, 500, current_date, 'efectivo', 'sena')$$, (select id from ids where clave='res4')),
  'finanzas puede registrar una seña');
select is((select estado::text from public.reservas where id = (select id from ids where clave='res4')), 'senada', 'la seña de finanzas pasa la reserva a señada');

-- Seña cambia el estado
select pg_temp.como('11111111-1111-1111-1111-111111111111');
insert into ids select 'res3', public.guardar_reserva(
  (select id from ids where clave='orgA'), null,
  jsonb_build_object('sucursal_id', (select id from ids where clave='sucA'), 'cliente_id', (select id from ids where clave='cliA'),
                     'titulo', 'Quince', 'estado', 'consulta', 'inicio', '2027-08-14 21:00-03', 'fin', '2027-08-15 05:00-03', 'precio_total', 100000),
  jsonb_build_array(jsonb_build_object('espacio_id', (select id from ids where clave='espA1'))));
select public.registrar_pago((select id from ids where clave='res3'), 30000, current_date, 'transferencia', 'sena');
select is((select estado::text from public.reservas where id = (select id from ids where clave='res3')), 'senada', 'la seña pasa la reserva a señada');
select is((select saldo from public.v_reservas_saldo where reserva_id = (select id from ids where clave='res3')), 70000.00::numeric, 'saldo calculado');

-- Propietario y roles
select throws_like(
  format($$update public.membresias set activo = false where usuario_id = '11111111-1111-1111-1111-111111111111' and organizacion_id = %L$$,
         (select id from ids where clave='orgA')),
  '%al menos un propietario%', 'no se puede dejar la organización sin propietario');
select throws_like(
  format($$delete from public.rol_permisos where rol_id = (select id from public.roles where organizacion_id = %L and clave = 'propietario') and permiso = 'pagos.ver'$$,
         (select id from ids where clave='orgA')),
  '%Propietario%', 'los permisos del propietario son inmutables');
select throws_ok(
  format($$update public.organizaciones set plan_clave = 'empresa' where id = %L$$, (select id from ids where clave='orgA')),
  '42501', null, 'el plan no se cambia por update directo');

-- Auditoría
select ok((select count(*) from public.auditoria where tabla = 'reservas' and organizacion_id = (select id from ids where clave='orgA')) > 0,
          'las reservas quedan auditadas');
select pg_temp.como('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.auditoria where organizacion_id = (select id from ids where clave='orgA')), 0, 'B no ve la auditoría de A');

-- Baja de cuenta: requiere confirmar con el nombre exacto y se purga a los 30 días
select pg_temp.como('11111111-1111-1111-1111-111111111111');
select throws_like(format($$select public.solicitar_baja_organizacion(%L, 'otro nombre')$$, (select id from ids where clave='orgA')),
  '%nombre exacto%', 'la baja exige confirmar el nombre');
select lives_ok(format($$select public.solicitar_baja_organizacion(%L, 'Salón A')$$, (select id from ids where clave='orgA')),
  'la propietaria solicita la baja');
select pg_temp.como_admin();
update public.organizaciones set baja_solicitada_at = now() - interval '31 days' where id = (select id from ids where clave='orgA');
select is(public.purgar_organizaciones_dadas_de_baja(), 1, 'la purga elimina la cuenta con reservas, cobros y auditoría');
select is((select count(*)::int from public.reservas where organizacion_id = (select id from ids where clave='orgA')), 0, 'no quedan reservas de la cuenta purgada');

select * from finish();
rollback;
