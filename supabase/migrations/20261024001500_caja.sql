-- =============================================================================
-- Festy · Migración 15: caja por cuenta.
--
-- Cuentas de dinero (efectivo, banco, Mercado Pago…) con saldo inicial. Cada
-- cobro, gasto y garantía queda asociado a una cuenta: la elegida al registrarlo
-- o, si no se elige, la que tiene asociado ese medio de pago. Las transferencias
-- mueven dinero entre cuentas. El saldo de una cuenta = saldo inicial + cobros
-- + garantías cobradas − gastos − garantías devueltas ± transferencias.
-- =============================================================================

insert into public.permisos (clave, modulo, descripcion, orden) values
  ('caja.ver',       'Finanzas', 'Ver la caja: saldos y movimientos por cuenta', 75),
  ('caja.gestionar', 'Finanzas', 'Configurar cuentas y registrar transferencias', 76)
on conflict (clave) do nothing;

update public.roles_plantilla set permisos = permisos || array['caja.ver','caja.gestionar']
 where clave in ('propietario','administrador','finanzas') and not 'caja.ver' = any (permisos);
insert into public.rol_permisos (organizacion_id, rol_id, permiso)
select r.organizacion_id, r.id, p from public.roles r, unnest(array['caja.ver','caja.gestionar']) p
 where r.clave in ('propietario','administrador','finanzas')
on conflict do nothing;

create table public.cuentas (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  nombre          text not null check (length(trim(nombre)) between 2 and 60),
  tipo            text not null default 'otro' check (tipo in ('efectivo','banco','mercadopago','otro')),
  -- medios de pago que se acreditan/debitan en esta cuenta si no se elige otra
  medios          text[] not null default '{}',
  saldo_inicial   numeric(14,2) not null default 0,
  activo          boolean not null default true,
  creado_at       timestamptz not null default now(),
  unique (organizacion_id, id),
  unique (organizacion_id, nombre)
);
create trigger cuentas_auditoria after insert or update or delete on public.cuentas for each row execute function public.auditar();

-- Un medio de pago va a una sola cuenta activa.
create or replace function public.validar_medios_cuenta()
returns trigger language plpgsql set search_path = '' as $$
declare v_medio text;
begin
  if not (new.medios <@ array['efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro']) then
    raise exception 'Medio de pago desconocido.' using errcode = '23514';
  end if;
  if new.activo then
    select m into v_medio from unnest(new.medios) m
     where exists (select 1 from public.cuentas c where c.organizacion_id = new.organizacion_id and c.id <> new.id
                     and c.activo and m = any (c.medios))
     limit 1;
    if v_medio is not null then
      raise exception 'El medio "%" ya está asociado a otra cuenta.', v_medio using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger cuentas_validar before insert or update on public.cuentas for each row execute function public.validar_medios_cuenta();

create table public.transferencias (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  fecha           date not null,
  desde_cuenta_id uuid not null,
  hacia_cuenta_id uuid not null,
  monto           numeric(14,2) not null check (monto > 0),
  descripcion     text,
  registrado_por  uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  check (desde_cuenta_id <> hacia_cuenta_id),
  foreign key (organizacion_id, desde_cuenta_id) references public.cuentas(organizacion_id, id),
  foreign key (organizacion_id, hacia_cuenta_id) references public.cuentas(organizacion_id, id)
);
create index transferencias_org_fecha_idx on public.transferencias (organizacion_id, fecha);
create trigger transferencias_auditoria after insert or update or delete on public.transferencias for each row execute function public.auditar();

alter table public.pagos add column cuenta_id uuid,
  add foreign key (organizacion_id, cuenta_id) references public.cuentas(organizacion_id, id);
alter table public.gastos add column cuenta_id uuid,
  add foreign key (organizacion_id, cuenta_id) references public.cuentas(organizacion_id, id);
alter table public.garantias add column cobro_cuenta_id uuid, add column devolucion_cuenta_id uuid,
  add foreign key (organizacion_id, cobro_cuenta_id) references public.cuentas(organizacion_id, id),
  add foreign key (organizacion_id, devolucion_cuenta_id) references public.cuentas(organizacion_id, id);

-- Cuenta asociada a un medio de pago.
create or replace function public.cuenta_de_medio(p_org uuid, p_medio text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.cuentas
   where organizacion_id = p_org and activo and p_medio = any (medios)
     and (current_user not in ('authenticated', 'anon') or public.es_miembro(p_org))
   order by creado_at limit 1
$$;
revoke execute on function public.cuenta_de_medio(uuid, text) from public, anon;
grant execute on function public.cuenta_de_medio(uuid, text) to authenticated;

create or replace function public.asignar_cuenta_movimiento()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_table_name in ('pagos', 'gastos') then
    if new.cuenta_id is null then new.cuenta_id := public.cuenta_de_medio(new.organizacion_id, new.medio); end if;
  else  -- garantias
    if new.cobro_medio is not null and new.cobro_cuenta_id is null then
      new.cobro_cuenta_id := public.cuenta_de_medio(new.organizacion_id, new.cobro_medio);
    end if;
    if new.devolucion_medio is not null and new.devolucion_cuenta_id is null then
      new.devolucion_cuenta_id := public.cuenta_de_medio(new.organizacion_id, new.devolucion_medio);
    end if;
  end if;
  return new;
end $$;
create trigger pagos_cuenta before insert on public.pagos for each row execute function public.asignar_cuenta_movimiento();
create trigger gastos_cuenta before insert or update of medio, cuenta_id on public.gastos for each row execute function public.asignar_cuenta_movimiento();
create trigger garantias_cuenta before insert or update on public.garantias for each row execute function public.asignar_cuenta_movimiento();

-- La cuenta de un cobro tampoco se modifica después de registrado.
create or replace function public.proteger_pago()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.anulado then
    raise exception 'El cobro ya está anulado.' using errcode = '42501';
  end if;
  if (new.fecha, new.monto, new.medio, new.concepto, new.reserva_id, new.organizacion_id, new.registrado_por, new.numero_comprobante, new.cuenta_id)
     is distinct from (old.fecha, old.monto, old.medio, old.concepto, old.reserva_id, old.organizacion_id, old.registrado_por, old.numero_comprobante, old.cuenta_id) then
    raise exception 'Un cobro registrado no se puede modificar; anulalo y registralo nuevamente.' using errcode = '42501';
  end if;
  if new.anulado then
    if coalesce(trim(new.anulado_motivo), '') = '' then
      raise exception 'Indicá el motivo de la anulación.' using errcode = '23514';
    end if;
    new.anulado_at := now();
    new.anulado_por := auth.uid();
  end if;
  return new;
end $$;

-- Cuentas iniciales para cada organización (nuevas y existentes).
create or replace function public.crear_cuentas_iniciales(p_org uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.cuentas (organizacion_id, nombre, tipo, medios) values
    (p_org, 'Efectivo', 'efectivo', array['efectivo']),
    (p_org, 'Banco', 'banco', array['transferencia','tarjeta_debito','tarjeta_credito','cheque']),
    (p_org, 'Mercado Pago', 'mercadopago', array['mercadopago'])
  on conflict (organizacion_id, nombre) do nothing;
$$;
revoke execute on function public.crear_cuentas_iniciales(uuid) from public, anon, authenticated;

create or replace function public.al_crear_organizacion_cuentas()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.crear_cuentas_iniciales(new.id);
  return null;
end $$;
create trigger organizaciones_cuentas after insert on public.organizaciones for each row execute function public.al_crear_organizacion_cuentas();

select public.crear_cuentas_iniciales(id) from public.organizaciones;
alter table public.pagos disable trigger pagos_proteger;  -- solo para completar la cuenta de los cobros existentes
update public.pagos p set cuenta_id = public.cuenta_de_medio(p.organizacion_id, p.medio) where cuenta_id is null;
alter table public.pagos enable trigger pagos_proteger;
update public.gastos g set cuenta_id = public.cuenta_de_medio(g.organizacion_id, g.medio) where cuenta_id is null;
update public.garantias g set cobro_cuenta_id = public.cuenta_de_medio(g.organizacion_id, g.cobro_medio)
 where cobro_medio is not null and cobro_cuenta_id is null;
update public.garantias g set devolucion_cuenta_id = public.cuenta_de_medio(g.organizacion_id, g.devolucion_medio)
 where devolucion_medio is not null and devolucion_cuenta_id is null;

-- RLS
alter table public.cuentas enable row level security;
alter table public.transferencias enable row level security;
create policy cuentas_lectura on public.cuentas for select to authenticated
  using (public.es_miembro(organizacion_id));  -- los nombres de cuentas se usan en los formularios de cobro y gasto
create policy cuentas_alta on public.cuentas for insert to authenticated with check (public.tiene_permiso(organizacion_id, 'caja.gestionar'));
create policy cuentas_edicion on public.cuentas for update to authenticated
  using (public.tiene_permiso(organizacion_id, 'caja.gestionar')) with check (public.tiene_permiso(organizacion_id, 'caja.gestionar'));
create policy cuentas_baja on public.cuentas for delete to authenticated using (public.tiene_permiso(organizacion_id, 'caja.gestionar'));
create policy transferencias_lectura on public.transferencias for select to authenticated using (public.tiene_permiso(organizacion_id, 'caja.ver'));
create policy transferencias_alta on public.transferencias for insert to authenticated with check (public.tiene_permiso(organizacion_id, 'caja.gestionar'));
create policy transferencias_baja on public.transferencias for delete to authenticated using (public.tiene_permiso(organizacion_id, 'caja.gestionar'));
grant select, insert, update, delete on public.cuentas to authenticated;
grant select, insert, delete on public.transferencias to authenticated;

-- Movimientos de dinero de una organización (uso interno de los SP de caja).
create or replace function public.movimientos_caja(p_org uuid)
returns table (cuenta_id uuid, fecha date, tipo text, descripcion text, monto numeric, reserva_id uuid, origen_id uuid)
language sql stable security definer set search_path = '' as $$
  select p.cuenta_id, p.fecha, 'cobro', format('#%s %s', r.numero, r.titulo), p.monto, p.reserva_id, p.id
    from public.pagos p join public.reservas r on r.id = p.reserva_id where p.organizacion_id = p_org and not p.anulado
  union all
  select g.cuenta_id, g.fecha, 'gasto', g.descripcion || coalesce(' · ' || g.proveedor, ''), -g.monto, g.reserva_id, g.id
    from public.gastos g where g.organizacion_id = p_org
  union all
  select g.cobro_cuenta_id, g.cobro_fecha, 'garantia_cobro', format('#%s %s', r.numero, r.titulo), g.monto, g.reserva_id, g.id
    from public.garantias g join public.reservas r on r.id = g.reserva_id where g.organizacion_id = p_org and g.cobro_fecha is not null
  union all
  select g.devolucion_cuenta_id, g.devolucion_fecha, 'garantia_devolucion', format('#%s %s', r.numero, r.titulo),
         -g.devolucion_monto, g.reserva_id, g.id
    from public.garantias g join public.reservas r on r.id = g.reserva_id
   where g.organizacion_id = p_org and g.devolucion_fecha is not null and g.devolucion_monto > 0
  union all
  select t.desde_cuenta_id, t.fecha, 'transferencia', 'Transferencia a ' || c.nombre || coalesce(' · ' || t.descripcion, ''), -t.monto, null, t.id
    from public.transferencias t join public.cuentas c on c.id = t.hacia_cuenta_id where t.organizacion_id = p_org
  union all
  select t.hacia_cuenta_id, t.fecha, 'transferencia', 'Transferencia desde ' || c.nombre || coalesce(' · ' || t.descripcion, ''), t.monto, null, t.id
    from public.transferencias t join public.cuentas c on c.id = t.desde_cuenta_id where t.organizacion_id = p_org
$$;
revoke execute on function public.movimientos_caja(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- SP de la API
-- -----------------------------------------------------------------------------
create or replace function api.sp_cuentas_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(c) order by c.creado_at)) from public.cuentas c where c.organizacion_id = p_org
$$;

create or replace function api.sp_cuenta_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
  v_medios text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p_datos->'medios', '[]')) x), '{}');
begin
  if p_id is null then
    insert into public.cuentas (organizacion_id, nombre, tipo, medios, saldo_inicial)
    values (p_org, trim(p_datos->>'nombre'), coalesce(p_datos->>'tipo', 'otro'), v_medios, coalesce((p_datos->>'saldo_inicial')::numeric, 0))
    returning to_jsonb(cuentas.*) into v;
  else
    update public.cuentas set nombre = trim(p_datos->>'nombre'), tipo = coalesce(p_datos->>'tipo', tipo), medios = v_medios,
           saldo_inicial = coalesce((p_datos->>'saldo_inicial')::numeric, saldo_inicial),
           activo = coalesce((p_datos->>'activo')::boolean, activo)
     where id = p_id and organizacion_id = p_org returning to_jsonb(cuentas.*) into v;
    if v is null then raise exception 'No se encontró la cuenta o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

create or replace function api.sp_transferencia_crear(p_org uuid, p_datos jsonb)
returns uuid language sql set search_path = '' as $$
  insert into public.transferencias (organizacion_id, fecha, desde_cuenta_id, hacia_cuenta_id, monto, descripcion)
  values (p_org, (p_datos->>'fecha')::date, (p_datos->>'desde_cuenta_id')::uuid, (p_datos->>'hacia_cuenta_id')::uuid,
          (p_datos->>'monto')::numeric, nullif(trim(coalesce(p_datos->>'descripcion', '')), ''))
  returning id
$$;

-- Caja: saldo actual de cada cuenta y movimientos del período.
create or replace function public.caja_resumen(p_org uuid, p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.exigir_permiso(p_org, 'caja.ver');
  return (
    with m as (select * from public.movimientos_caja(p_org)),
         per as (select * from m where m.fecha between p_desde and p_hasta)
    select jsonb_build_object(
      'cuentas', (select api.lista(jsonb_agg(jsonb_build_object(
          'id', c.id, 'nombre', c.nombre, 'tipo', c.tipo, 'activo', c.activo, 'medios', c.medios, 'saldo_inicial', c.saldo_inicial,
          'saldo', c.saldo_inicial + coalesce((select sum(m.monto) from m where m.cuenta_id = c.id), 0),
          'ingresos', coalesce((select sum(per.monto) from per where per.cuenta_id = c.id and per.monto > 0), 0),
          'egresos', coalesce((select -sum(per.monto) from per where per.cuenta_id = c.id and per.monto < 0), 0)) order by c.creado_at))
          from public.cuentas c where c.organizacion_id = p_org),
      'sin_cuenta', coalesce((select sum(m.monto) from m where m.cuenta_id is null), 0),
      'periodo', jsonb_build_object(
          'cobros', coalesce((select sum(monto) from per where tipo = 'cobro'), 0),
          'gastos', coalesce((select -sum(monto) from per where tipo = 'gasto'), 0),
          'garantias_cobradas', coalesce((select sum(monto) from per where tipo = 'garantia_cobro'), 0),
          'garantias_devueltas', coalesce((select -sum(monto) from per where tipo = 'garantia_devolucion'), 0)),
      'movimientos', (select api.lista(jsonb_agg(jsonb_build_object(
          'fecha', x.fecha, 'tipo', x.tipo, 'descripcion', x.descripcion, 'monto', x.monto, 'reserva_id', x.reserva_id, 'id', x.origen_id,
          'cuenta_id', x.cuenta_id, 'cuenta', (select nombre from public.cuentas where id = x.cuenta_id)) order by x.fecha desc, x.tipo))
          from (select * from per order by fecha desc limit 1000) x))
  );
end $$;
revoke execute on function public.caja_resumen(uuid, date, date) from public, anon;
grant execute on function public.caja_resumen(uuid, date, date) to authenticated;

create or replace function api.sp_caja(p_org uuid, p_desde date, p_hasta date)
returns jsonb language sql stable set search_path = '' as $$ select public.caja_resumen(p_org, p_desde, p_hasta) $$;

-- Cobro, gasto y garantías aceptan la cuenta elegida. registrar_pago suma
-- p_cuenta al final (opcional): las llamadas existentes siguen funcionando.
drop function public.registrar_pago(uuid, numeric, date, text, text, text, text);
create function public.registrar_pago(
  p_reserva uuid, p_monto numeric, p_fecha date, p_medio text, p_concepto text,
  p_referencia text default null, p_notas text default null, p_cuenta uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_r public.reservas;
  v_id uuid;
begin
  select * into v_r from public.reservas where id = p_reserva for update;
  if not found then
    raise exception 'La reserva no existe.' using errcode = 'P0002';
  end if;
  perform public.exigir_permiso(v_r.organizacion_id, 'pagos.registrar');
  if v_r.estado = 'cancelada' then
    raise exception 'No se pueden registrar cobros en una reserva cancelada.' using errcode = '23514';
  end if;
  if p_cuenta is not null and not exists (select 1 from public.cuentas where id = p_cuenta and organizacion_id = v_r.organizacion_id and activo) then
    raise exception 'La cuenta no existe o está inactiva.' using errcode = '23514';
  end if;

  insert into public.pagos (organizacion_id, reserva_id, fecha, monto, medio, concepto, referencia, notas, registrado_por, cuenta_id)
  values (v_r.organizacion_id, p_reserva, p_fecha, p_monto, p_medio, p_concepto, nullif(p_referencia, ''), nullif(p_notas, ''), auth.uid(), p_cuenta)
  returning id into v_id;

  if p_concepto = 'sena' and v_r.estado in ('consulta', 'tentativa') then
    if not exists (select 1 from public.reserva_espacios where reserva_id = p_reserva) then
      raise exception 'Asigná un espacio a la reserva antes de registrar la seña.' using errcode = '23514';
    end if;
    update public.reservas set estado = 'senada' where id = p_reserva;
  end if;
  return v_id;
end $$;
revoke execute on function public.registrar_pago(uuid, numeric, date, text, text, text, text, uuid) from public, anon;
grant execute on function public.registrar_pago(uuid, numeric, date, text, text, text, text, uuid) to authenticated;

create or replace function api.sp_pago_registrar(p_reserva uuid, p_datos jsonb)
returns uuid language sql set search_path = '' as $$
  select public.registrar_pago(p_reserva, (p_datos->>'monto')::numeric, (p_datos->>'fecha')::date, p_datos->>'medio', p_datos->>'concepto',
                               nullif(p_datos->>'referencia', ''), nullif(p_datos->>'notas', ''), nullif(p_datos->>'cuenta_id', '')::uuid)
$$;

create or replace function api.sp_gasto_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if p_id is null then
    insert into public.gastos (organizacion_id, sucursal_id, reserva_id, fecha, categoria, descripcion, proveedor, monto, medio, cuenta_id)
    values (p_org, nullif(p_datos->>'sucursal_id', '')::uuid, nullif(p_datos->>'reserva_id', '')::uuid, (p_datos->>'fecha')::date,
            coalesce(p_datos->>'categoria', 'otro'), trim(p_datos->>'descripcion'), nullif(trim(coalesce(p_datos->>'proveedor', '')), ''),
            (p_datos->>'monto')::numeric, coalesce(p_datos->>'medio', 'efectivo'), nullif(p_datos->>'cuenta_id', '')::uuid);
  else
    update public.gastos set sucursal_id = nullif(p_datos->>'sucursal_id', '')::uuid, fecha = (p_datos->>'fecha')::date,
           categoria = coalesce(p_datos->>'categoria', categoria), descripcion = trim(p_datos->>'descripcion'),
           proveedor = nullif(trim(coalesce(p_datos->>'proveedor', '')), ''), monto = (p_datos->>'monto')::numeric,
           medio = coalesce(p_datos->>'medio', medio),
           cuenta_id = coalesce(nullif(p_datos->>'cuenta_id', '')::uuid, public.cuenta_de_medio(p_org, coalesce(p_datos->>'medio', medio)))
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró el gasto o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;

create or replace function api.sp_garantia_cobrar(p_reserva uuid, p_fecha date, p_medio text, p_referencia text default null, p_cuenta uuid default null)
returns int language plpgsql set search_path = '' as $$
declare v_n int;
begin
  v_n := public.cobrar_garantia(p_reserva, p_fecha, p_medio, p_referencia);
  if p_cuenta is not null then perform public.asignar_cuenta_garantia(p_reserva, 'cobro', p_cuenta); end if;
  return v_n;
end $$;

create or replace function api.sp_garantia_devolver(p_reserva uuid, p_fecha date, p_monto_devuelto numeric, p_medio text,
                                                    p_motivo text default null, p_cuenta uuid default null)
returns int language plpgsql set search_path = '' as $$
declare v_n int;
begin
  v_n := public.devolver_garantia(p_reserva, p_fecha, p_monto_devuelto, p_medio, p_motivo);
  if p_cuenta is not null then perform public.asignar_cuenta_garantia(p_reserva, 'devolucion', p_cuenta); end if;
  return v_n;
end $$;
drop function if exists api.sp_garantia_cobrar(uuid, date, text, text);
drop function if exists api.sp_garantia_devolver(uuid, date, numeric, text, text);

create or replace function public.asignar_cuenta_garantia(p_reserva uuid, p_momento text, p_cuenta uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_g public.garantias;
begin
  select * into v_g from public.garantias where reserva_id = p_reserva;
  perform public.exigir_permiso(v_g.organizacion_id, 'pagos.registrar');
  if not exists (select 1 from public.cuentas where id = p_cuenta and organizacion_id = v_g.organizacion_id and activo) then
    raise exception 'La cuenta no existe o está inactiva.' using errcode = '23514';
  end if;
  if p_momento = 'cobro' then
    update public.garantias set cobro_cuenta_id = p_cuenta where id = v_g.id;
  else
    update public.garantias set devolucion_cuenta_id = p_cuenta where id = v_g.id;
  end if;
end $$;
revoke execute on function public.asignar_cuenta_garantia(uuid, text, uuid) from public, anon;
grant execute on function public.asignar_cuenta_garantia(uuid, text, uuid) to authenticated;

revoke execute on all functions in schema api from public, anon;
grant execute on all functions in schema api to authenticated;
revoke execute on function api.sp_push_pendientes(int), api.sp_push_marcar(bigint[], text[]) from authenticated;
grant execute on function api.sp_invitacion_ver(text), api.lista(jsonb) to anon;
