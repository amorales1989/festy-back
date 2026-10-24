-- =============================================================================
-- Festy · Migración 16: proveedores, costos por evento y rentabilidad.
--
-- Cada evento puede tener costos (lo tercerizado o comprado para ese evento),
-- opcionalmente de un proveedor. Pagar un costo registra un gasto vinculado, así
-- que el pago impacta en la caja y en Gastos. Rentabilidad del evento =
-- total del evento − costos − gastos directos del evento sin costo asociado.
-- Permisos: se reutilizan gastos.ver (ver) y gastos.gestionar (cargar/pagar).
-- =============================================================================

create table public.proveedores (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  nombre          text not null check (length(trim(nombre)) between 2 and 120),
  rubro           text,
  telefono        text,
  email           text,
  notas           text,
  activo          boolean not null default true,
  es_ejemplo      boolean not null default false,
  creado_at       timestamptz not null default now(),
  unique (organizacion_id, id),
  unique (organizacion_id, nombre)
);
create trigger proveedores_auditoria after insert or update or delete on public.proveedores for each row execute function public.auditar();

create table public.costos_evento (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  reserva_id      uuid not null,
  proveedor_id    uuid,
  reserva_item_id uuid unique references public.reserva_items(id) on delete set null,
  descripcion     text not null check (length(trim(descripcion)) between 2 and 240),
  monto           numeric(14,2) not null check (monto > 0),
  vencimiento     date,
  es_ejemplo      boolean not null default false,
  creado_at       timestamptz not null default now(),
  unique (organizacion_id, id),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete cascade,
  foreign key (organizacion_id, proveedor_id) references public.proveedores(organizacion_id, id) on delete set null (proveedor_id)
);
create index costos_evento_reserva_idx on public.costos_evento (reserva_id);
create trigger costos_evento_auditoria after insert or update or delete on public.costos_evento for each row execute function public.auditar();

alter table public.gastos add column costo_id uuid, add column proveedor_id uuid,
  add foreign key (organizacion_id, costo_id) references public.costos_evento(organizacion_id, id) on delete set null (costo_id),
  add foreign key (organizacion_id, proveedor_id) references public.proveedores(organizacion_id, id) on delete set null (proveedor_id);
create index gastos_costo_idx on public.gastos (costo_id) where costo_id is not null;

alter table public.proveedores enable row level security;
alter table public.costos_evento enable row level security;
create policy proveedores_lectura on public.proveedores for select to authenticated using (public.tiene_permiso(organizacion_id, 'gastos.ver'));
create policy proveedores_alta on public.proveedores for insert to authenticated with check (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
create policy proveedores_edicion on public.proveedores for update to authenticated
  using (public.tiene_permiso(organizacion_id, 'gastos.gestionar')) with check (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
create policy proveedores_baja on public.proveedores for delete to authenticated using (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
create policy costos_lectura on public.costos_evento for select to authenticated using (public.tiene_permiso(organizacion_id, 'gastos.ver'));
create policy costos_alta on public.costos_evento for insert to authenticated with check (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
create policy costos_edicion on public.costos_evento for update to authenticated
  using (public.tiene_permiso(organizacion_id, 'gastos.gestionar')) with check (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
create policy costos_baja on public.costos_evento for delete to authenticated using (public.tiene_permiso(organizacion_id, 'gastos.gestionar'));
grant select, insert, update, delete on public.proveedores, public.costos_evento to authenticated;

-- Un costo no puede quedar por debajo de lo ya pagado.
create or replace function public.validar_costo_evento()
returns trigger language plpgsql set search_path = '' as $$
declare v_pagado numeric;
begin
  select coalesce(sum(monto), 0) into v_pagado from public.gastos where costo_id = new.id;
  if new.monto < v_pagado then
    raise exception 'El costo no puede ser menor a lo ya pagado (%).', public.formato_ars(v_pagado) using errcode = '23514';
  end if;
  return new;
end $$;
create trigger costos_evento_validar before update of monto on public.costos_evento for each row execute function public.validar_costo_evento();

-- -----------------------------------------------------------------------------
-- SP de la API
-- -----------------------------------------------------------------------------
create or replace function api.sp_proveedores_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(p) || jsonb_build_object(
           'comprometido', coalesce((select sum(c.monto) from public.costos_evento c where c.proveedor_id = p.id), 0),
           'pagado', coalesce((select sum(g.monto) from public.gastos g where g.proveedor_id = p.id), 0)) order by p.nombre))
    from public.proveedores p where p.organizacion_id = p_org
$$;

create or replace function api.sp_proveedor_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  if p_id is null then
    insert into public.proveedores (organizacion_id, nombre, rubro, telefono, email, notas)
    values (p_org, trim(p_datos->>'nombre'), nullif(trim(coalesce(p_datos->>'rubro', '')), ''), nullif(trim(coalesce(p_datos->>'telefono', '')), ''),
            nullif(lower(trim(coalesce(p_datos->>'email', ''))), ''), nullif(trim(coalesce(p_datos->>'notas', '')), ''))
    returning to_jsonb(proveedores.*) into v;
  else
    update public.proveedores set nombre = trim(p_datos->>'nombre'), rubro = nullif(trim(coalesce(p_datos->>'rubro', '')), ''),
           telefono = nullif(trim(coalesce(p_datos->>'telefono', '')), ''), email = nullif(lower(trim(coalesce(p_datos->>'email', ''))), ''),
           notas = nullif(trim(coalesce(p_datos->>'notas', '')), '')
     where id = p_id and organizacion_id = p_org returning to_jsonb(proveedores.*) into v;
    if v is null then raise exception 'No se encontró el proveedor o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

-- Costos del evento con lo pagado, y el resumen de rentabilidad.
create or replace function api.sp_costos_evento(p_reserva uuid)
returns jsonb language sql stable set search_path = '' as $$
  with c as (
    select c.*, p.nombre as proveedor_nombre, coalesce((select sum(g.monto) from public.gastos g where g.costo_id = c.id), 0) as pagado
      from public.costos_evento c left join public.proveedores p on p.id = c.proveedor_id where c.reserva_id = p_reserva
  ), directos as (
    select coalesce(sum(g.monto), 0) as total from public.gastos g where g.reserva_id = p_reserva and g.costo_id is null
  )
  select jsonb_build_object(
    'costos', (select api.lista(jsonb_agg(to_jsonb(c) || jsonb_build_object('pendiente', c.monto - c.pagado) order by c.creado_at)) from c),
    'gastos_directos', (select total from directos),
    'total_evento', (select r.precio_total from public.reservas r where r.id = p_reserva),
    'total_costos', (select coalesce(sum(monto), 0) from c) + (select total from directos),
    'pagado', (select coalesce(sum(pagado), 0) from c),
    'ganancia', (select r.precio_total from public.reservas r where r.id = p_reserva) - (select coalesce(sum(monto), 0) from c) - (select total from directos))
$$;

create or replace function api.sp_costo_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns uuid language plpgsql set search_path = '' as $$
declare v_id uuid;
begin
  if p_id is null then
    insert into public.costos_evento (organizacion_id, reserva_id, proveedor_id, descripcion, monto, vencimiento)
    values (p_org, (p_datos->>'reserva_id')::uuid, nullif(p_datos->>'proveedor_id', '')::uuid, trim(p_datos->>'descripcion'),
            (p_datos->>'monto')::numeric, nullif(p_datos->>'vencimiento', '')::date)
    returning id into v_id;
  else
    update public.costos_evento set proveedor_id = nullif(p_datos->>'proveedor_id', '')::uuid, descripcion = trim(p_datos->>'descripcion'),
           monto = (p_datos->>'monto')::numeric, vencimiento = nullif(p_datos->>'vencimiento', '')::date
     where id = p_id and organizacion_id = p_org returning id into v_id;
    if v_id is null then raise exception 'No se encontró el costo o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v_id;
end $$;

-- Pagar (total o parcial) un costo: registra un gasto vinculado.
create or replace function api.sp_costo_pagar(p_costo uuid, p_datos jsonb)
returns uuid language plpgsql set search_path = '' as $$
declare
  v_c public.costos_evento;
  v_pagado numeric;
  v_monto numeric := (p_datos->>'monto')::numeric;
  v_id uuid;
begin
  select * into v_c from public.costos_evento where id = p_costo for update;
  if not found then raise exception 'No se encontró el costo o no tenés acceso.' using errcode = 'P0002'; end if;
  select coalesce(sum(monto), 0) into v_pagado from public.gastos where costo_id = p_costo;
  if v_monto is null or v_monto <= 0 then raise exception 'Ingresá el monto a pagar.' using errcode = '23514'; end if;
  if v_monto > v_c.monto - v_pagado then
    raise exception 'El pago supera lo que falta pagar (%).', public.formato_ars(v_c.monto - v_pagado) using errcode = '23514';
  end if;
  insert into public.gastos (organizacion_id, sucursal_id, reserva_id, fecha, categoria, descripcion, proveedor, monto, medio, cuenta_id, costo_id, proveedor_id)
  select v_c.organizacion_id, r.sucursal_id, v_c.reserva_id, (p_datos->>'fecha')::date, 'proveedores', v_c.descripcion, p.nombre, v_monto,
         coalesce(p_datos->>'medio', 'efectivo'), nullif(p_datos->>'cuenta_id', '')::uuid, v_c.id, v_c.proveedor_id
    from public.reservas r left join public.proveedores p on p.id = v_c.proveedor_id
   where r.id = v_c.reserva_id
  returning id into v_id;
  return v_id;
end $$;

-- Crea los costos de los servicios del evento que tienen costo en el catálogo.
create or replace function api.sp_costos_desde_catalogo(p_reserva uuid)
returns int language plpgsql set search_path = '' as $$
declare v_n int;
begin
  insert into public.costos_evento (organizacion_id, reserva_id, reserva_item_id, descripcion, monto)
  select i.organizacion_id, i.reserva_id, i.id, i.descripcion, round(s.costo * i.cantidad, 2)
    from public.reserva_items i join public.servicios s on s.id = i.servicio_id
   where i.reserva_id = p_reserva and s.costo > 0
     and not exists (select 1 from public.costos_evento c where c.reserva_item_id = i.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Rentabilidad de los eventos del período (por fecha del evento).
create or replace function api.sp_rentabilidad(p_org uuid, p_desde date, p_hasta date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_tz text;
begin
  if not (public.tiene_permiso(p_org, 'gastos.ver') and public.tiene_permiso(p_org, 'pagos.ver')) then
    raise exception 'Necesitás permiso para ver cobros y gastos.' using errcode = '42501';
  end if;
  select zona_horaria into v_tz from public.organizaciones where id = p_org;
  return (
    with ev as (
      select r.id, r.numero, r.titulo, r.inicio, r.estado, r.precio_total,
             (select c.nombre from public.clientes c where c.id = r.cliente_id) as cliente,
             coalesce((select sum(c.monto) from public.costos_evento c where c.reserva_id = r.id), 0)
               + coalesce((select sum(g.monto) from public.gastos g where g.reserva_id = r.id and g.costo_id is null), 0) as costos,
             coalesce((select sum(p.monto) from public.pagos p where p.reserva_id = r.id and not p.anulado), 0) as cobrado
        from public.reservas r
       where r.organizacion_id = p_org and r.estado in ('tentativa','senada','confirmada','finalizada')
         and (r.inicio at time zone v_tz)::date between p_desde and p_hasta
    )
    select jsonb_build_object(
      'eventos', (select api.lista(jsonb_agg(to_jsonb(ev) || jsonb_build_object('ganancia', ev.precio_total - ev.costos,
                    'margen', case when ev.precio_total > 0 then round((ev.precio_total - ev.costos) * 100 / ev.precio_total, 1) end) order by ev.inicio)) from ev),
      'totales', (select jsonb_build_object('facturado', coalesce(sum(precio_total), 0), 'costos', coalesce(sum(costos), 0),
                    'ganancia', coalesce(sum(precio_total - costos), 0), 'cobrado', coalesce(sum(cobrado), 0),
                    'margen', case when sum(precio_total) > 0 then round(sum(precio_total - costos) * 100 / sum(precio_total), 1) end) from ev))
  );
end $$;

-- Borrado y activación genéricos: se suman las tablas nuevas.
create or replace function api.sp_eliminar(p_entidad text, p_id uuid)
returns void language plpgsql set search_path = '' as $$
declare v_n int;
begin
  if p_entidad not in ('salones','sucursales','espacios','recursos','feriados','clientes','servicios','gastos','tareas',
                       'entrevistas','presupuestos','reservas','bloqueos','cuotas','reserva_items',
                       'proveedores','costos_evento','transferencias','cuentas') then
    raise exception 'Entidad no válida: %', p_entidad using errcode = '22023';
  end if;
  execute format('delete from public.%I where id = $1', p_entidad) using p_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No se encontró el registro o no tenés permiso para eliminarlo.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_activar(p_entidad text, p_id uuid, p_activo boolean)
returns void language plpgsql set search_path = '' as $$
declare v_n int;
begin
  if p_entidad not in ('sucursales','espacios','servicios','recursos','proveedores','cuentas') then
    raise exception 'Entidad no válida: %', p_entidad using errcode = '22023';
  end if;
  execute format('update public.%I set activo = $2 where id = $1', p_entidad) using p_id, p_activo;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No se encontró el registro o no tenés permiso para modificarlo.' using errcode = '42501'; end if;
end $$;

-- Datos de ejemplo: proveedores y costos sobre los eventos de ejemplo.
create or replace function public.cargar_ejemplos_proveedores(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_dj uuid; v_cat uuid; v_deco uuid; v_r record; v_i int := 0; v_costo uuid;
begin
  perform public.exigir_permiso(p_org, 'sedes.gestionar');
  insert into public.proveedores (organizacion_id, nombre, rubro, telefono, es_ejemplo) values
    (p_org, 'DJ Martín Sosa (ejemplo)', 'Música', '1155550101', true) returning id into v_dj;
  insert into public.proveedores (organizacion_id, nombre, rubro, telefono, es_ejemplo) values
    (p_org, 'Catering Las Delicias (ejemplo)', 'Catering', '1155550202', true) returning id into v_cat;
  insert into public.proveedores (organizacion_id, nombre, rubro, telefono, es_ejemplo) values
    (p_org, 'Deco Bella (ejemplo)', 'Decoración', '1155550303', true) returning id into v_deco;
  for v_r in select id, precio_total, inicio, sucursal_id from public.reservas
              where organizacion_id = p_org and es_ejemplo and estado in ('senada','confirmada','finalizada') order by inicio loop
    v_i := v_i + 1;
    insert into public.costos_evento (organizacion_id, reserva_id, proveedor_id, descripcion, monto, es_ejemplo)
    values (p_org, v_r.id, v_cat, 'Catering', round(v_r.precio_total * 0.35, -3), true) returning id into v_costo;
    if v_i % 2 = 1 then  -- algunos ya pagados en parte
      insert into public.gastos (organizacion_id, sucursal_id, reserva_id, fecha, categoria, descripcion, proveedor, monto, medio, costo_id, proveedor_id, es_ejemplo)
      values (p_org, v_r.sucursal_id, v_r.id, least(current_date, (v_r.inicio)::date), 'proveedores', 'Catering', 'Catering Las Delicias (ejemplo)',
              round(v_r.precio_total * 0.15, -3), 'transferencia', v_costo, v_cat, true);
    end if;
    insert into public.costos_evento (organizacion_id, reserva_id, proveedor_id, descripcion, monto, es_ejemplo)
    values (p_org, v_r.id, v_dj, 'DJ y sonido', 250000, true);
    if v_i % 3 = 0 then
      insert into public.costos_evento (organizacion_id, reserva_id, proveedor_id, descripcion, monto, es_ejemplo)
      values (p_org, v_r.id, v_deco, 'Decoración y centros de mesa', 180000, true);
    end if;
  end loop;
end $$;
revoke execute on function public.cargar_ejemplos_proveedores(uuid) from public, anon;
grant execute on function public.cargar_ejemplos_proveedores(uuid) to authenticated;

create or replace function api.sp_ejemplos_cargar(p_org uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  v := public.cargar_datos_ejemplo(p_org);
  perform public.cargar_ejemplos_proveedores(p_org);
  return v;
end $$;

create or replace function api.sp_ejemplos_borrar(p_org uuid)
returns void language plpgsql set search_path = '' as $$
begin
  perform public.borrar_datos_ejemplo(p_org);  -- borra gastos y eventos de ejemplo (los costos caen con el evento)
  delete from public.proveedores p where p.organizacion_id = p_org and p.es_ejemplo
     and not exists (select 1 from public.costos_evento c where c.proveedor_id = p.id)
     and not exists (select 1 from public.gastos g where g.proveedor_id = p.id);
end $$;

revoke execute on all functions in schema api from public, anon;
grant execute on all functions in schema api to authenticated;
revoke execute on function api.sp_push_pendientes(int), api.sp_push_marcar(bigint[], text[]) from authenticated;
grant execute on function api.sp_invitacion_ver(text), api.lista(jsonb) to anon;
