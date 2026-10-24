-- Pruebas: cobro de suscripciones de la plataforma (cobertura y privacidad).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(13);

insert into auth.users (id, email, aud, role) values ('abababab-0000-0000-0000-000000000001', 'duenio@susc.test', 'authenticated', 'authenticated');
create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.servicio() returns void language sql as $$
  select set_config('role', 'service_role', true), set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated, service_role;

select pg_temp.como('abababab-0000-0000-0000-000000000001');
insert into k select 'org', api.sp_organizacion_crear('Salón Suscripto', 'America/Argentina/Buenos_Aires');

-- Una empresa no ve ni toca su cobro
select throws_ok($$select api.sp_plataforma_empresas()$$, '42501', null, 'una empresa no lista las empresas');
select throws_ok(format($$select api.sp_plataforma_pago_registrar(%L, '{"fecha":"2027-01-10","monto":30000}', 'yo')$$, (select id from k where clave='org')),
  '42501', null, 'una empresa no registra pagos');
select throws_ok(format($$update public.organizaciones set suscripcion_precio = 1 where id = %L$$, (select id from k where clave='org')),
  '42501', null, 'una empresa no cambia su precio');
select throws_ok($$select count(*) from public.suscripcion_pagos$$, '42501', null, 'una empresa no accede a los pagos de suscripción');

-- Administración (service_role)
select pg_temp.servicio();
create temp table t0 as select x from jsonb_array_elements(api.sp_plataforma_empresas()) x where x->>'id' = (select id::text from k where clave='org');
select is((select (x->>'precio')::numeric from t0), 30000::numeric, 'tarifa: $30.000 con hasta una sede');
-- dos sedes más (como la dueña) → 3 sedes = 30.000 + 2 × 15.000
select pg_temp.como('abababab-0000-0000-0000-000000000001');
insert into k select 'sal', (api.sp_salon_guardar((select id from k where clave='org'), null, '{"nombre":"Marca"}')->>'id')::uuid;
select api.sp_sucursal_guardar((select id from k where clave='org'), null, jsonb_build_object('salon_id', (select id from k where clave='sal'), 'nombre', n))
  from unnest(array['Centro', 'Norte', 'Sur']) n;
select pg_temp.servicio();
select is((select (x->>'precio')::numeric from jsonb_array_elements(api.sp_plataforma_empresas()) x where x->>'id' = (select id::text from k where clave='org')),
  60000::numeric, 'tarifa: $15.000 por cada sede extra');
select api.sp_plataforma_precio((select id from k where clave='org'), 25000);
select is((select (x->>'precio')::numeric from jsonb_array_elements(api.sp_plataforma_empresas()) x where x->>'id' = (select id::text from k where clave='org')),
  25000::numeric, 'un precio especial reemplaza la tarifa');
select is(api.sp_plataforma_pago_registrar((select id from k where clave='org'), '{"fecha":"2027-01-10","monto":30000,"medio":"transferencia"}', 'admin@festy')->>'cubre_hasta',
  '2027-02-10', 'el primer pago cubre un mes desde la fecha');
select is(api.sp_plataforma_pago_registrar((select id from k where clave='org'), '{"fecha":"2027-02-05","monto":90000,"meses":3}', 'admin@festy')->>'cubre_hasta',
  '2027-05-10', 'un pago adelantado extiende desde donde terminaba la cobertura');
select is(api.sp_plataforma_pago_registrar((select id from k where clave='org'), '{"fecha":"2027-08-01","monto":30000}', 'admin@festy')->>'cubre_desde',
  '2027-08-01', 'si estaba vencida, la cobertura arranca en la fecha del pago');
create temp table e as select x from jsonb_array_elements(api.sp_plataforma_empresas()) x where x->>'id' = (select id::text from k where clave='org');
select is((select x->>'pagado_hasta' from e), '2027-09-01', 'pagado hasta = fin de la última cobertura');
select is((select (x->'ultimo_pago'->>'monto')::numeric from e), 30000::numeric, 'último pago y precio en el listado');
select api.sp_plataforma_pago_eliminar((api.sp_plataforma_pagos((select id from k where clave='org'))->0->>'id')::uuid);
select is((select x->>'pagado_hasta' from jsonb_array_elements(api.sp_plataforma_empresas()) x where x->>'id' = (select id::text from k where clave='org')), '2027-05-10',
  'borrar un pago recalcula hasta cuándo está pagada');

select * from finish();
rollback;
