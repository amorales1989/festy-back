-- Pruebas: capacidad mínima, servicios contratados/adicionales y depósitos de garantía.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(28);

insert into auth.users (id, email, aud, role) values
  ('cccccccc-0000-0000-0000-000000000001', 'duenio@garantias.test', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-000000000002', 'operativo@garantias.test', 'authenticated', 'authenticated');

create function pg_temp.como(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.admin() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;
create temp table k (clave text primary key, id uuid);
grant all on k to authenticated;

select pg_temp.como('cccccccc-0000-0000-0000-000000000001');
insert into k select 'org', public.crear_organizacion('Salón Garantías');
with s as (insert into public.salones (organizacion_id, nombre) select id, 'Marca' from k where clave = 'org' returning id, organizacion_id),
     su as (insert into public.sucursales (organizacion_id, salon_id, nombre) select organizacion_id, id, 'Centro' from s returning id, organizacion_id),
     e as (insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima, capacidad_minima, garantia_sugerida)
           select organizacion_id, id, 'Salón', 200, 80, 300000 from su returning id, sucursal_id)
insert into k select 'esp', id from e union all select 'suc', sucursal_id from e;
with c as (insert into public.clientes (organizacion_id, nombre) select id, 'Juana Ruiz' from k where clave = 'org' returning id)
insert into k select 'cli', id from c;

-- Capacidad
select throws_ok(format($$update public.espacios set capacidad_minima = 500 where id = %L$$, (select id from k where clave='esp')),
  '23514', null, 'el mínimo no puede superar la capacidad máxima');

-- Presupuesto con garantía → evento con servicios y garantía pendiente
insert into k select 'pre', public.guardar_presupuesto((select id from k where clave='org'), null, jsonb_build_object(
  'cliente_id', (select id from k where clave='cli'), 'titulo', 'Casamiento Ruiz', 'tipo_evento', 'casamiento', 'fecha_evento', '2027-11-20',
  'hora_inicio', '21:00', 'hora_fin', '05:00', 'espacio_id', (select id from k where clave='esp'), 'invitados', 100,
  'descuento', 100000, 'sena_porcentaje', 30, 'cantidad_cuotas', 1, 'garantia_monto', 300000),
  jsonb_build_array(jsonb_build_object('descripcion', 'Menú', 'cantidad', 100, 'unidad', 'persona', 'precio_unitario', 20000),
                    jsonb_build_object('descripcion', 'DJ', 'cantidad', 1, 'unidad', 'evento', 'precio_unitario', 500000)));
select is((select garantia_monto from public.presupuestos where id = (select id from k where clave='pre')), 300000.00, 'el presupuesto guarda la garantía');
insert into k select 'res', public.aceptar_presupuesto((select id from k where clave='pre'), 'confirmada');
select is((select count(*)::int from public.reserva_items where reserva_id = (select id from k where clave='res')), 2, 'los ítems pasan al evento');
select is((select precio_total from public.reservas where id = (select id from k where clave='res')), 2400000.00, 'total = ítems - descuento');
select is((select estado from public.garantias where reserva_id = (select id from k where clave='res')), 'pendiente', 'la garantía queda pedida');
select is((select sum(monto) from public.cuotas where reserva_id = (select id from k where clave='res')), 2400000.00, 'las cuotas no incluyen la garantía');

-- Adicional pedido después
select public.agregar_item_reserva((select id from k where clave='res'), 'Cabina de fotos', 1, 'evento', 280000, null, true, true, '2027-11-10');
select is((select precio_total from public.reservas where id = (select id from k where clave='res')), 2680000.00, 'el adicional suma al total');
select is((select monto from public.cuotas where reserva_id = (select id from k where clave='res') and concepto like 'Adicional:%'), 280000.00,
  'el adicional genera su cuota');
select is((select sum(monto) from public.cuotas where reserva_id = (select id from k where clave='res')), 2680000.00, 'plan de cuotas = total');

-- Con servicios cargados, el total no se edita a mano
update public.reservas set precio_total = 1 where id = (select id from k where clave='res');
select is((select precio_total from public.reservas where id = (select id from k where clave='res')), 2680000.00, 'el total manual se ignora');
delete from public.reserva_items where reserva_id = (select id from k where clave='res') and descripcion = 'DJ';
select is((select precio_total from public.reservas where id = (select id from k where clave='res')), 2180000.00, 'quitar un servicio recalcula');

-- Permisos: personal operativo no maneja garantías
select pg_temp.admin();
insert into public.membresias (organizacion_id, usuario_id, rol_id)
select (select id from k where clave='org'), 'cccccccc-0000-0000-0000-000000000002',
       (select id from public.roles where organizacion_id = (select id from k where clave='org') and clave = 'operativo');
select pg_temp.como('cccccccc-0000-0000-0000-000000000002');
select is((select count(*)::int from public.garantias), 0, 'operativo no ve garantías');
select throws_ok(format($$select public.cobrar_garantia(%L, current_date, 'efectivo')$$, (select id from k where clave='res')),
  '42501', null, 'operativo no puede cobrar garantías');
select throws_ok(format($$insert into public.reserva_items (organizacion_id, reserva_id, descripcion, precio_unitario) values (%L, %L, 'x', 1)$$,
  (select id from k where clave='org'), (select id from k where clave='res')), '42501', null, 'operativo no agrega servicios');

-- Ciclo de la garantía
select pg_temp.como('cccccccc-0000-0000-0000-000000000001');
select throws_like(format($$select public.devolver_garantia(%L, current_date, 300000, 'efectivo')$$, (select id from k where clave='res')),
  '%todavía no se cobró%', 'no se devuelve lo que no se cobró');
select is(public.cobrar_garantia((select id from k where clave='res'), current_date, 'transferencia', 'OP 123'), 1, 'recibo de garantía N° 1');
select throws_like(format($$select public.pedir_garantia(%L, 500000)$$, (select id from k where clave='res')),
  '%ya fue cobrada%', 'no se cambia el monto de una garantía cobrada');
select is((select count(*)::int from public.pagos where reserva_id = (select id from k where clave='res')), 0, 'la garantía no es un cobro del evento');
select is((select saldo from public.v_reservas_saldo where reserva_id = (select id from k where clave='res')), 2180000.00, 'ni reduce el saldo');
select throws_like(format($$select public.devolver_garantia(%L, current_date, 200000, 'efectivo')$$, (select id from k where clave='res')),
  '%motivo%', 'retener parte exige motivo');
select throws_like(format($$select public.devolver_garantia(%L, current_date, 400000, 'efectivo')$$, (select id from k where clave='res')),
  '%entre $ 0%', 'no se devuelve más de lo cobrado');
select is(public.devolver_garantia((select id from k where clave='res'), current_date, 250000, 'transferencia', 'Mantel quemado y vaso roto'), 2,
  'constancia de devolución N° 2');
select ok((select estado = 'retenida' and devolucion_monto = 250000 from public.garantias where reserva_id = (select id from k where clave='res')),
  'queda registrada la retención parcial');
select throws_like(format($$select public.devolver_garantia(%L, current_date, 0, 'efectivo', 'otra')$$, (select id from k where clave='res')),
  '%ya fue devuelta%', 'no se devuelve dos veces');
select throws_ok(format($$update public.garantias set monto = 1 where reserva_id = %L$$, (select id from k where clave='res')),
  '42501', null, 'la garantía no se modifica directamente');

-- Un evento con garantía cobrada no se puede borrar
select throws_ok(format($$delete from public.reservas where id = %L$$, (select id from k where clave='res')), '23503', null,
  'no se borra un evento con garantía cobrada');

-- Recordatorio de devolución
select pg_temp.admin();
with r as (insert into public.reservas (organizacion_id, sucursal_id, cliente_id, titulo, estado, inicio, fin)
  select (select id from k where clave='org'), (select id from k where clave='suc'), (select id from k where clave='cli'), 'Evento pasado', 'consulta',
         now() - interval '3 days', now() - interval '2 days 18 hours' returning id)
insert into k select 'pasado', id from r;
insert into public.garantias (organizacion_id, reserva_id, monto, estado, cobro_fecha, cobro_medio, numero_recibo)
values ((select id from k where clave='org'), (select id from k where clave='pasado'), 100000, 'cobrada', current_date - 5, 'efectivo', 99);
select is(public.generar_recordatorios_garantias(), 1, 'recuerda devolver la garantía de un evento terminado');
select is(public.generar_recordatorios_garantias(), 0, 'sin duplicar el recordatorio');

select * from finish();
rollback;
