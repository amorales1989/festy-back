-- Pruebas de onboarding, datos de ejemplo, panel, búsqueda e importación.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(21);

insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'onb@test.local', 'authenticated', 'authenticated');
select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);

create temp table ctx as select public.crear_organizacion('Quinta Los Álamos') as org;
grant all on ctx to authenticated;

select is((public.checklist_configuracion((select org from ctx))->>'sucursal')::boolean, false, 'checklist: sin sucursal al inicio');

select ok((public.cargar_datos_ejemplo((select org from ctx))->>'reservas')::int >= 5, 'carga reservas de ejemplo');
select ok((select count(*) from public.reservas where es_ejemplo and organizacion_id = (select org from ctx)) >= 5, 'reservas marcadas como ejemplo');
select is((public.checklist_configuracion((select org from ctx))->>'datos_ejemplo')::boolean, true, 'checklist detecta datos de ejemplo');
select is((public.checklist_configuracion((select org from ctx))->>'sucursal')::boolean, false, 'los ejemplos no cuentan como configuración real');

create temp table panel as
  select public.panel_resumen((select org from ctx), date_trunc('month', current_date)::date,
                              (date_trunc('month', current_date) + interval '1 month - 1 day')::date) as p;
select ok(jsonb_array_length((select p->'eventos_hoy' from panel)) >= 1, 'panel: evento de hoy');
select ok(jsonb_array_length((select p->'proximas' from panel)) >= 2, 'panel: próximas reservas');
select ok((select (p->>'consultas_abiertas')::int from panel) >= 1, 'panel: consultas abiertas');
select ok((select (p->>'tentativas')::int from panel) >= 1, 'panel: tentativas');
select ok((select (p->>'ingresos')::numeric from panel) >= 0, 'panel: ingresos calculados');
select ok((select (p->>'deuda_vencida')::numeric from panel) > 0, 'panel: deuda vencida derivada de cuotas');
select ok((select (p->>'ocupacion_pct')::numeric from panel) > 0, 'panel: ocupación > 0');

select ok(jsonb_array_length(public.buscar_global((select org from ctx), 'lucia')) >= 1, 'búsqueda sin acentos encuentra "Lucía"');
select ok(jsonb_array_length(public.buscar_global((select org from ctx), '#1')) >= 1, 'búsqueda por número de reserva');

select public.borrar_datos_ejemplo((select org from ctx));
select is((select count(*)::int from public.reservas where es_ejemplo and organizacion_id = (select org from ctx)), 0, 'borra las reservas de ejemplo');
select is((select count(*)::int from public.espacios where organizacion_id = (select org from ctx)), 0, 'borra los espacios de ejemplo');

-- Importación
select set_config('role', 'postgres', true);
insert into public.salones (organizacion_id, nombre) select org, 'Los Álamos' from ctx;
insert into public.sucursales (organizacion_id, salon_id, nombre) select org, (select id from public.salones where organizacion_id = ctx.org limit 1), 'Ruta 20' from ctx;
insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima) select org, (select id from public.sucursales where organizacion_id = ctx.org limit 1), 'Salón Álamo', 120 from ctx;
select set_config('role', 'authenticated', true);

select is(public.importar_clientes((select org from ctx), '[
  {"nombre":"Juan Paz","telefono":"351-111-2222","email":"juan@ej.com"},
  {"nombre":"Juan P.","telefono":"3511112222"},
  {"nombre":"X"}]'::jsonb) - 'errores',
  '{"importados":1,"duplicados":1}'::jsonb, 'importa clientes detectando duplicados por teléfono');

select is((public.importar_reservas((select org from ctx), '[
  {"cliente":"Juan Paz","telefono":"351-111-2222","espacio":"salon alamo","fecha":"14/11/2027","hora_inicio":"21:00","hora_fin":"04:00","estado":"Confirmada","invitados":"80","precio":"1.500.000,50"},
  {"cliente":"Otra","espacio":"salon alamo","fecha":"14/11/2027","hora_inicio":"22:00","hora_fin":"02:00","estado":"confirmada"},
  {"cliente":"Otra","espacio":"inexistente","fecha":"15/11/2027"},
  {"cliente":"Otra","espacio":"salon alamo","fecha":"2027-11-20"}]'::jsonb)->>'importados')::int,
  1, 'importa reservas: 1 ok, conflicto, espacio inexistente y fecha inválida rechazados');

select is(public.ocupa_dia(tstzrange('2026-11-14 21:00-03', '2026-11-15 06:00-03'), '2026-11-15', 'America/Argentina/Buenos_Aires'), false,
  'una fiesta nocturna que termina a la madrugada no ocupa el domingo');
select is(public.ocupa_dia(tstzrange('2026-11-14 21:00-03', '2026-11-15 06:00-03'), '2026-11-14', 'America/Argentina/Buenos_Aires'), true,
  'sí ocupa el día en que empieza');
select is(public.ocupa_dia(tstzrange('2026-11-14 21:00-03', '2026-11-15 14:00-03'), '2026-11-15', 'America/Argentina/Buenos_Aires'), true,
  'si sigue pasado el mediodía, ocupa el día siguiente');

select * from finish();
rollback;
