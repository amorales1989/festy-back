-- Pruebas: estadísticas de la empresa (totales, comparación, embudo, permisos y aislamiento).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('ffffffff-0000-0000-0000-000000000001', 'duenia@estad.test', 'authenticated', 'authenticated'),
  ('ffffffff-0000-0000-0000-000000000002', 'operativo@estad.test', 'authenticated', 'authenticated'),
  ('ffffffff-0000-0000-0000-000000000003', 'otra@estad.test', 'authenticated', 'authenticated');
create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated;

select pg_temp.como('ffffffff-0000-0000-0000-000000000001');
insert into k select 'org', api.sp_organizacion_crear('Salón Estadísticas', 'America/Argentina/Buenos_Aires');
insert into k select 'sal', (api.sp_salon_guardar((select id from k where clave='org'), null, '{"nombre":"Marca"}')->>'id')::uuid;
insert into k select 'suc', (api.sp_sucursal_guardar((select id from k where clave='org'), null,
  jsonb_build_object('salon_id', (select id from k where clave='sal'), 'nombre', 'Centro'))->>'id')::uuid;
insert into k select 'esp', (api.sp_espacio_guardar((select id from k where clave='org'), null,
  jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'nombre', 'Salón', 'capacidad_maxima', 300), null)->>'id')::uuid;
insert into k select 'cli', (api.sp_cliente_guardar((select id from k where clave='org'), null, '{"nombre":"Cliente Uno","origen":"instagram"}')->>'id')::uuid;

-- Marzo 2027: dos eventos confirmados (casamiento 2.000.000 y cumpleaños 1.000.000), una consulta y una cancelada.
-- Febrero 2027 (período anterior): un evento de 500.000.
create function pg_temp.evento(p_titulo text, p_tipo text, p_estado text, p_inicio text, p_fin text, p_total numeric, p_inv int) returns uuid language sql as $$
  select api.sp_reserva_guardar((select id from k where clave='org'), null,
    jsonb_build_object('sucursal_id', (select id from k where clave='suc'), 'cliente_id', (select id from k where clave='cli'), 'titulo', p_titulo,
                       'tipo_evento', p_tipo, 'estado', p_estado, 'inicio', p_inicio, 'fin', p_fin, 'precio_total', p_total, 'invitados', p_inv),
    jsonb_build_array(jsonb_build_object('espacio_id', (select id from k where clave='esp'))))
$$;
insert into k select 'e1', pg_temp.evento('Boda', 'casamiento', 'confirmada', '2027-03-06 21:00-03', '2027-03-07 05:00-03', 2000000, 150);
insert into k select 'e2', pg_temp.evento('Cumple', 'cumpleanos', 'confirmada', '2027-03-13 21:00-03', '2027-03-14 03:00-03', 1000000, 50);
insert into k select 'e3', pg_temp.evento('Consulta', 'quince', 'consulta', '2027-03-20 21:00-03', '2027-03-21 03:00-03', 0, 100);
insert into k select 'e0', pg_temp.evento('Febrero', 'cumpleanos', 'confirmada', '2027-02-13 21:00-03', '2027-02-14 03:00-03', 500000, 80);
select api.sp_pago_registrar((select id from k where clave='e1'), '{"monto":600000,"fecha":"2027-03-01","medio":"transferencia","concepto":"cuota"}');
select api.sp_gasto_guardar((select id from k where clave='org'), null, '{"fecha":"2027-03-10","descripcion":"Limpieza","monto":100000,"categoria":"limpieza"}');
select api.sp_costo_guardar((select id from k where clave='org'), null,
  jsonb_build_object('reserva_id', (select id from k where clave='e1'), 'descripcion', 'Catering', 'monto', 700000));

create temp table est as select api.sp_estadisticas((select id from k where clave='org'), '2027-03-01', '2027-03-31') as d;
grant all on est to authenticated;
select is((select (d->'resumen'->>'eventos')::int from est), 2, 'eventos del mes (señados/confirmados/finalizados)');
select is((select (d->'resumen'->>'eventos_ant')::int from est), 1, 'eventos del período anterior (febrero)');
select is((select (d->'resumen'->>'facturado')::numeric from est), 3000000::numeric, 'facturado del mes');
select is((select (d->'resumen'->>'ticket_promedio')::numeric from est), 1500000::numeric, 'ticket promedio');
select is((select (d->'resumen'->>'cobrado')::numeric from est), 600000::numeric, 'cobrado del mes');
select is((select (d->'resumen'->>'ganancia_eventos')::numeric from est), 2300000::numeric, 'ganancia = facturado − costos de los eventos');
select is((select (d->'resumen'->>'invitados')::int from est), 200, 'invitados del mes');
select is((select d->'por_tipo'->0->>'tipo' from est), 'casamiento', 'por tipo de evento');
select is((select (d->'por_dia_semana'->5->>'eventos')::int from est), 2, 'los dos eventos fueron sábado');
select is((select d->>'agrupacion' from est), 'semana', 'un mes se agrupa por semana');

-- Personal operativo: ve eventos pero no montos
select pg_temp.admin();
insert into public.membresias (organizacion_id, usuario_id, rol_id)
select (select id from k where clave='org'), 'ffffffff-0000-0000-0000-000000000002',
       (select id from public.roles where organizacion_id = (select id from k where clave='org') and clave = 'operativo');
select pg_temp.como('ffffffff-0000-0000-0000-000000000002');
select is((api.sp_estadisticas((select id from k where clave='org'), '2027-03-01', '2027-03-31')->'resumen'->>'eventos')::int, 2, 'operativo ve la cantidad de eventos');
select is(api.sp_estadisticas((select id from k where clave='org'), '2027-03-01', '2027-03-31')->'resumen'->'facturado', 'null'::jsonb, 'pero no ve montos');

-- Otra empresa
select pg_temp.como('ffffffff-0000-0000-0000-000000000003');
select api.sp_organizacion_crear('Otra', 'America/Argentina/Buenos_Aires');
select throws_ok(format($$select api.sp_estadisticas(%L, '2027-03-01', '2027-03-31')$$, (select id from k where clave='org')), '42501', null,
  'otra empresa no ve las estadísticas');
select throws_ok(format($$select api.sp_estadisticas(%L, '2027-03-31', '2027-03-01')$$, (select id from k where clave='org')), '42501', null,
  'ni con un rango inválido');

select * from finish();
rollback;
