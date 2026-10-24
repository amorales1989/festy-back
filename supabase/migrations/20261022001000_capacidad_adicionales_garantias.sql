-- =============================================================================
-- Festy · Migración 10: capacidad mínima, servicios contratados (adicionales)
-- y depósitos de garantía.
--
-- * Espacios: mínimo de invitados (aviso) y garantía sugerida.
-- * reserva_items: lo que se contrató para el evento. Si un evento tiene ítems,
--   su precio total = suma de ítems - descuento (se recalcula solo).
-- * garantias: depósito reintegrable. NO es un cobro del evento: no suma a
--   ingresos ni al saldo. Ciclo: pendiente → cobrada → devuelta (total) o
--   retenida (devolución parcial o nula, con motivo).
-- =============================================================================

alter table public.espacios
  add column capacidad_minima int check (capacidad_minima is null or capacidad_minima >= 1),
  add column garantia_sugerida numeric(14,2) not null default 0 check (garantia_sugerida >= 0);
alter table public.espacios add constraint espacios_capacidad_coherente
  check (capacidad_minima is null or capacidad_minima <= capacidad_maxima);

alter table public.organizaciones
  add column dias_devolucion_garantia int not null default 7 check (dias_devolucion_garantia between 0 and 90),
  add column ultimo_numero_garantia int not null default 0;

create or replace function public.proteger_organizacion()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and (
       new.plan_clave is distinct from old.plan_clave
    or new.suscripcion_estado is distinct from old.suscripcion_estado
    or new.prueba_hasta is distinct from old.prueba_hasta
    or new.estado is distinct from old.estado
    or new.baja_solicitada_at is distinct from old.baja_solicitada_at
    or new.creado_por is distinct from old.creado_por
    or new.ultimo_numero_reserva is distinct from old.ultimo_numero_reserva
    or new.ultimo_numero_presupuesto is distinct from old.ultimo_numero_presupuesto
    or new.ultimo_numero_comprobante is distinct from old.ultimo_numero_comprobante
    or new.ultimo_numero_garantia is distinct from old.ultimo_numero_garantia) then
    raise exception 'Estos datos de la cuenta solo pueden cambiarse desde la sección Plan o Baja.' using errcode = '42501';
  end if;
  return new;
end $$;

alter table public.presupuestos add column garantia_monto numeric(14,2) not null default 0 check (garantia_monto >= 0);
alter table public.reservas add column descuento numeric(14,2) not null default 0 check (descuento >= 0);

-- -----------------------------------------------------------------------------
-- Servicios contratados por evento
-- -----------------------------------------------------------------------------
create table public.reserva_items (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  reserva_id      uuid not null,
  servicio_id     uuid,
  descripcion     text not null check (length(trim(descripcion)) between 1 and 300),
  cantidad        numeric(10,2) not null default 1 check (cantidad > 0),
  unidad          text not null default 'evento' check (unidad in ('evento','persona','hora','unidad')),
  precio_unitario numeric(14,2) not null check (precio_unitario >= 0),
  es_adicional    boolean not null default false,
  orden           int not null default 0,
  creado_at       timestamptz not null default now(),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete cascade,
  foreign key (organizacion_id, servicio_id) references public.servicios(organizacion_id, id) on delete set null (servicio_id)
);
create index reserva_items_reserva_idx on public.reserva_items (reserva_id, orden);

create or replace function public.total_items_reserva(p_reserva uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select sum(round(cantidad * precio_unitario, 2)) from public.reserva_items where reserva_id = p_reserva
$$;

create or replace function public.recalcular_total_reserva()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid := coalesce(new.reserva_id, old.reserva_id); v_total numeric;
begin
  v_total := public.total_items_reserva(v_id);
  if v_total is not null then
    update public.reservas set precio_total = greatest(v_total - descuento, 0) where id = v_id;
  end if;
  return null;
end $$;
create trigger reserva_items_recalcular after insert or update or delete on public.reserva_items
  for each row execute function public.recalcular_total_reserva();

-- Si el evento tiene servicios cargados, el total no se edita a mano.
create or replace function public.reservas_total_por_items()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_total numeric;
begin
  v_total := public.total_items_reserva(new.id);
  if v_total is not null then
    new.descuento := least(new.descuento, v_total);
    new.precio_total := greatest(v_total - new.descuento, 0);
  end if;
  return new;
end $$;
create trigger reservas_total_items before update on public.reservas
  for each row execute function public.reservas_total_por_items();

-- Agrega un servicio (por ejemplo, un adicional pedido después) y opcionalmente su cuota.
create or replace function public.agregar_item_reserva(
  p_reserva uuid, p_descripcion text, p_cantidad numeric, p_unidad text, p_precio numeric,
  p_servicio uuid default null, p_es_adicional boolean default true, p_crear_cuota boolean default false, p_vencimiento date default null)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_r public.reservas; v_id uuid; v_tz text;
begin
  select * into v_r from public.reservas where id = p_reserva;
  if not found then raise exception 'El evento no existe.' using errcode = 'P0002'; end if;
  if v_r.estado = 'cancelada' then raise exception 'El evento está cancelado.' using errcode = '23514'; end if;
  insert into public.reserva_items (organizacion_id, reserva_id, servicio_id, descripcion, cantidad, unidad, precio_unitario, es_adicional, orden)
  values (v_r.organizacion_id, p_reserva, p_servicio, trim(p_descripcion), p_cantidad, coalesce(p_unidad, 'evento'), p_precio, p_es_adicional,
          coalesce((select max(orden) + 1 from public.reserva_items where reserva_id = p_reserva), 1))
  returning id into v_id;
  if p_crear_cuota and round(p_cantidad * p_precio, 2) > 0 then
    select zona_horaria into v_tz from public.organizaciones where id = v_r.organizacion_id;
    insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto)
    values (v_r.organizacion_id, p_reserva, left('Adicional: ' || trim(p_descripcion), 120),
            coalesce(p_vencimiento, greatest((v_r.inicio at time zone v_tz)::date - 7, (now() at time zone v_tz)::date)),
            round(p_cantidad * p_precio, 2));
  end if;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- Depósitos de garantía
-- -----------------------------------------------------------------------------
create table public.garantias (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null,
  reserva_id         uuid not null unique,
  monto              numeric(14,2) not null check (monto > 0),
  estado             text not null default 'pendiente' check (estado in ('pendiente','cobrada','devuelta','retenida')),
  cobro_fecha        date,
  cobro_medio        text check (cobro_medio in ('efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro')),
  cobro_referencia   text,
  numero_recibo      int,
  cobrada_por        uuid references auth.users(id) on delete set null,
  devolucion_fecha   date,
  devolucion_monto   numeric(14,2),
  devolucion_medio   text check (devolucion_medio in ('efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro')),
  motivo_retencion   text,
  numero_devolucion  int,
  devuelta_por       uuid references auth.users(id) on delete set null,
  es_ejemplo         boolean not null default false,
  creado_at          timestamptz not null default now(),
  actualizado_at     timestamptz not null default now(),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete restrict,
  check (estado = 'pendiente' or (cobro_fecha is not null and cobro_medio is not null and numero_recibo is not null)),
  check (estado not in ('devuelta','retenida') or (devolucion_fecha is not null and devolucion_monto is not null and numero_devolucion is not null)),
  check (devolucion_monto is null or devolucion_monto between 0 and monto),
  check (estado <> 'devuelta' or devolucion_monto = monto),
  check (estado <> 'retenida' or (devolucion_monto < monto and length(trim(coalesce(motivo_retencion, ''))) >= 3))
);
create index garantias_org_estado_idx on public.garantias (organizacion_id, estado);
create trigger garantias_actualizado before update on public.garantias for each row execute function public.tocar_actualizado();
create trigger garantias_auditoria after insert or update or delete on public.garantias for each row execute function public.auditar();

-- Al eliminar un evento, se borra la garantía solo si todavía no se cobró.
create or replace function public.reservas_borrar_garantia_pendiente()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.garantias where reserva_id = old.id and estado = 'pendiente';
  return old;
end $$;
create trigger reservas_garantia_pendiente before delete on public.reservas
  for each row execute function public.reservas_borrar_garantia_pendiente();

create or replace function public.pedir_garantia(p_reserva uuid, p_monto numeric)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_id uuid; v_estado text;
begin
  select organizacion_id into v_org from public.reservas where id = p_reserva;
  if v_org is null then raise exception 'El evento no existe.' using errcode = 'P0002'; end if;
  perform public.exigir_permiso(v_org, 'pagos.registrar');
  if coalesce(p_monto, 0) <= 0 then raise exception 'Ingresá un monto mayor a 0.' using errcode = '23514'; end if;
  select id, estado into v_id, v_estado from public.garantias where reserva_id = p_reserva;
  if v_estado is not null and v_estado <> 'pendiente' then
    raise exception 'La garantía ya fue cobrada: no se puede cambiar el monto.' using errcode = 'P0001';
  end if;
  insert into public.garantias (organizacion_id, reserva_id, monto) values (v_org, p_reserva, p_monto)
  on conflict (reserva_id) do update set monto = excluded.monto
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.quitar_garantia(p_reserva uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_g public.garantias;
begin
  select * into v_g from public.garantias where reserva_id = p_reserva;
  if not found then return; end if;
  perform public.exigir_permiso(v_g.organizacion_id, 'pagos.registrar');
  if v_g.estado <> 'pendiente' then raise exception 'La garantía ya fue cobrada: registrá la devolución.' using errcode = 'P0001'; end if;
  delete from public.garantias where id = v_g.id;
end $$;

create or replace function public.cobrar_garantia(p_reserva uuid, p_fecha date, p_medio text, p_referencia text default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v_g public.garantias; v_n int; v_r public.reservas;
begin
  select * into v_g from public.garantias where reserva_id = p_reserva for update;
  if not found then raise exception 'Este evento no tiene garantía pedida.' using errcode = 'P0002'; end if;
  perform public.exigir_permiso(v_g.organizacion_id, 'pagos.registrar');
  if v_g.estado <> 'pendiente' then raise exception 'La garantía ya fue cobrada.' using errcode = 'P0001'; end if;
  update public.organizaciones set ultimo_numero_garantia = ultimo_numero_garantia + 1
   where id = v_g.organizacion_id returning ultimo_numero_garantia into v_n;
  update public.garantias set estado = 'cobrada', cobro_fecha = p_fecha, cobro_medio = p_medio,
         cobro_referencia = nullif(trim(coalesce(p_referencia, '')), ''), numero_recibo = v_n, cobrada_por = auth.uid()
   where id = v_g.id;
  select * into v_r from public.reservas where id = p_reserva;
  if not v_r.es_ejemplo then
    perform public.notificar(v_g.organizacion_id, array(select public.usuarios_con_permiso(v_g.organizacion_id, 'pagos.ver')), 'garantia',
      format('Garantía cobrada: %s', public.formato_ars(v_g.monto)), format('#%s %s', v_r.numero, v_r.titulo), format('/reservas/%s', p_reserva));
  end if;
  return v_n;
end $$;

create or replace function public.devolver_garantia(p_reserva uuid, p_fecha date, p_monto_devuelto numeric, p_medio text, p_motivo text default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v_g public.garantias; v_n int;
begin
  select * into v_g from public.garantias where reserva_id = p_reserva for update;
  if not found then raise exception 'Este evento no tiene garantía.' using errcode = 'P0002'; end if;
  perform public.exigir_permiso(v_g.organizacion_id, 'pagos.registrar');
  if v_g.estado = 'pendiente' then raise exception 'La garantía todavía no se cobró.' using errcode = 'P0001'; end if;
  if v_g.estado <> 'cobrada' then raise exception 'La garantía ya fue devuelta.' using errcode = 'P0001'; end if;
  if p_monto_devuelto is null or p_monto_devuelto < 0 or p_monto_devuelto > v_g.monto then
    raise exception 'El monto a devolver debe estar entre $ 0 y el total de la garantía (%).', public.formato_ars(v_g.monto) using errcode = '23514';
  end if;
  if p_monto_devuelto < v_g.monto and length(trim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Indicá el motivo por el que se retiene parte de la garantía (por ejemplo, daños).' using errcode = '23514';
  end if;
  update public.organizaciones set ultimo_numero_garantia = ultimo_numero_garantia + 1
   where id = v_g.organizacion_id returning ultimo_numero_garantia into v_n;
  update public.garantias set estado = case when p_monto_devuelto = v_g.monto then 'devuelta' else 'retenida' end,
         devolucion_fecha = p_fecha, devolucion_monto = p_monto_devuelto,
         devolucion_medio = case when p_monto_devuelto > 0 then p_medio end,
         motivo_retencion = nullif(trim(coalesce(p_motivo, '')), ''), numero_devolucion = v_n, devuelta_por = auth.uid()
   where id = v_g.id;
  return v_n;
end $$;

-- Recordatorio: garantías cobradas de eventos que ya terminaron.
create or replace function public.generar_recordatorios_garantias()
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select g.organizacion_id, u, 'garantia', format('Devolver garantía: %s', public.formato_ars(g.monto)),
         format('#%s %s · el evento ya terminó', r.numero, r.titulo), format('/reservas/%s', r.id), format('garantia:%s', g.id)
    from public.garantias g
    join public.reservas r on r.id = g.reserva_id
    cross join lateral public.usuarios_con_permiso(g.organizacion_id, 'pagos.registrar') u
   where g.estado = 'cobrada' and not g.es_ejemplo and r.fin < now()
  on conflict (usuario_id, clave) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.aceptar_presupuesto(p_id uuid, p_estado text default 'tentativa')
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_p public.presupuestos;
  v_tz text;
  v_esp public.espacios;
  v_reserva uuid;
  v_ini timestamptz; v_fin timestamptz;
  v_hoy date;
  v_sena numeric; v_resto numeric; v_cuota numeric;
  v_ultima date;
  i int;
begin
  select * into v_p from public.presupuestos where id = p_id for update;
  if not found then raise exception 'El presupuesto no existe.' using errcode = 'P0002'; end if;
  if not public.tiene_permiso(v_p.organizacion_id, 'presupuestos.gestionar') or not public.tiene_permiso(v_p.organizacion_id, 'reservas.crear') then
    raise exception 'No tenés permiso para aceptar presupuestos y crear eventos.' using errcode = '42501';
  end if;
  if v_p.estado = 'aceptado' then raise exception 'El presupuesto ya fue aceptado.' using errcode = 'P0001'; end if;
  if p_estado not in ('consulta','tentativa','confirmada') then raise exception 'Estado inválido.' using errcode = '22023'; end if;
  if v_p.fecha_evento is null or v_p.espacio_id is null then
    raise exception 'Para aceptar el presupuesto completá la fecha y el espacio del evento.' using errcode = '23514';
  end if;
  select zona_horaria into v_tz from public.organizaciones where id = v_p.organizacion_id;
  v_hoy := (now() at time zone v_tz)::date;
  select * into v_esp from public.espacios where id = v_p.espacio_id;
  v_ini := (v_p.fecha_evento + coalesce(v_p.hora_inicio, '21:00')) at time zone v_tz;
  v_fin := (v_p.fecha_evento + coalesce(v_p.hora_fin, '04:00')
            + case when coalesce(v_p.hora_fin, '04:00') <= coalesce(v_p.hora_inicio, '21:00') then interval '1 day' else interval '0' end) at time zone v_tz;

  v_reserva := public.guardar_reserva(v_p.organizacion_id, v_p.reserva_id, jsonb_build_object(
      'sucursal_id', v_esp.sucursal_id, 'cliente_id', v_p.cliente_id, 'titulo', v_p.titulo, 'tipo_evento', v_p.tipo_evento,
      'estado', p_estado, 'inicio', v_ini, 'fin', v_fin, 'invitados', v_p.invitados, 'precio_total', v_p.total,
      'notas', nullif(concat_ws(E'\n', format('Presupuesto #%s aceptado.', v_p.numero), v_p.notas), '')),
    jsonb_build_array(jsonb_build_object('espacio_id', v_p.espacio_id)));

  -- Servicios contratados: se copian los ítems; el total del evento se recalcula solo.
  update public.reservas set descuento = v_p.descuento where id = v_reserva;
  delete from public.reserva_items where reserva_id = v_reserva;
  insert into public.reserva_items (organizacion_id, reserva_id, servicio_id, descripcion, cantidad, unidad, precio_unitario, orden)
  select v_p.organizacion_id, v_reserva, i.servicio_id, i.descripcion, i.cantidad, i.unidad, i.precio_unitario, i.orden
    from public.presupuesto_items i where i.presupuesto_id = p_id;

  -- Depósito de garantía pedido en el presupuesto
  if v_p.garantia_monto > 0 and public.tiene_permiso(v_p.organizacion_id, 'pagos.registrar')
     and not exists (select 1 from public.garantias where reserva_id = v_reserva and estado <> 'pendiente') then
    perform public.pedir_garantia(v_reserva, v_p.garantia_monto);
  end if;

  -- Plan de cuotas: seña hoy + cuotas mensuales; la última vence 7 días antes del evento.
  if not exists (select 1 from public.cuotas where reserva_id = v_reserva) and v_p.total > 0
     and public.tiene_permiso(v_p.organizacion_id, 'pagos.registrar') then
    v_sena := round(v_p.total * v_p.sena_porcentaje / 100, 2);
    if v_sena > 0 then
      insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto) values (v_p.organizacion_id, v_reserva, 'Seña', v_hoy, v_sena);
    end if;
    v_resto := v_p.total - v_sena;
    if v_resto > 0 then
      v_ultima := greatest(v_p.fecha_evento - 7, v_hoy);
      if v_p.cantidad_cuotas <= 1 then
        insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto) values (v_p.organizacion_id, v_reserva, 'Saldo', v_ultima, v_resto);
      else
        v_cuota := trunc(v_resto / v_p.cantidad_cuotas, 2);
        for i in 1..v_p.cantidad_cuotas loop
          insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto)
          values (v_p.organizacion_id, v_reserva,
                  case when i = v_p.cantidad_cuotas then 'Saldo' else format('Cuota %s', i) end,
                  greatest(v_ultima - ((v_p.cantidad_cuotas - i) * 30), v_hoy),
                  case when i = v_p.cantidad_cuotas then v_resto - v_cuota * (v_p.cantidad_cuotas - 1) else v_cuota end);
        end loop;
      end if;
    end if;
  end if;

  update public.presupuestos set estado = 'aceptado', reserva_id = v_reserva where id = p_id;
  return v_reserva;
end $$;

create or replace function public.guardar_presupuesto(p_org uuid, p_id uuid, p_datos jsonb, p_items jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if v_id is null then
    insert into public.presupuestos (organizacion_id, cliente_id, reserva_id, espacio_id, titulo, tipo_evento, fecha_evento, hora_inicio, hora_fin,
                                     invitados, estado, valido_hasta, descuento, sena_porcentaje, cantidad_cuotas, condiciones, notas, garantia_monto)
    values (p_org, (p_datos->>'cliente_id')::uuid, nullif(p_datos->>'reserva_id', '')::uuid, nullif(p_datos->>'espacio_id', '')::uuid,
            p_datos->>'titulo', coalesce(p_datos->>'tipo_evento', 'otro'), nullif(p_datos->>'fecha_evento', '')::date,
            nullif(p_datos->>'hora_inicio', '')::time, nullif(p_datos->>'hora_fin', '')::time, nullif(p_datos->>'invitados', '')::int,
            coalesce(p_datos->>'estado', 'borrador'), nullif(p_datos->>'valido_hasta', '')::date, 0,
            coalesce(nullif(p_datos->>'sena_porcentaje', '')::numeric, 30), coalesce(nullif(p_datos->>'cantidad_cuotas', '')::int, 2),
            nullif(p_datos->>'condiciones', ''), nullif(p_datos->>'notas', ''),
            coalesce(nullif(p_datos->>'garantia_monto', '')::numeric, 0))
    returning id into v_id;
  else
    if exists (select 1 from public.presupuestos where id = v_id and estado = 'aceptado') then
      raise exception 'El presupuesto ya fue aceptado: para cambiarlo, editá el evento.' using errcode = 'P0001';
    end if;
    update public.presupuestos set
      cliente_id = (p_datos->>'cliente_id')::uuid, espacio_id = nullif(p_datos->>'espacio_id', '')::uuid,
      titulo = p_datos->>'titulo', tipo_evento = coalesce(p_datos->>'tipo_evento', 'otro'),
      fecha_evento = nullif(p_datos->>'fecha_evento', '')::date, hora_inicio = nullif(p_datos->>'hora_inicio', '')::time,
      hora_fin = nullif(p_datos->>'hora_fin', '')::time, invitados = nullif(p_datos->>'invitados', '')::int,
      estado = coalesce(p_datos->>'estado', estado), valido_hasta = coalesce(nullif(p_datos->>'valido_hasta', '')::date, valido_hasta),
      descuento = 0, sena_porcentaje = coalesce(nullif(p_datos->>'sena_porcentaje', '')::numeric, 30),
      cantidad_cuotas = coalesce(nullif(p_datos->>'cantidad_cuotas', '')::int, 2),
      condiciones = nullif(p_datos->>'condiciones', ''), notas = nullif(p_datos->>'notas', ''),
      garantia_monto = coalesce(nullif(p_datos->>'garantia_monto', '')::numeric, 0)
    where id = v_id and organizacion_id = p_org;
    if not found then
      raise exception 'El presupuesto no existe o no tenés permiso para editarlo.' using errcode = '42501';
    end if;
    delete from public.presupuesto_items where presupuesto_id = v_id;
  end if;

  insert into public.presupuesto_items (organizacion_id, presupuesto_id, servicio_id, descripcion, cantidad, unidad, precio_unitario, orden)
  select p_org, v_id, nullif(i->>'servicio_id', '')::uuid, i->>'descripcion', (i->>'cantidad')::numeric, coalesce(i->>'unidad', 'evento'),
         (i->>'precio_unitario')::numeric, ord::int
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as t(i, ord);

  -- El descuento se aplica al final, cuando el subtotal ya está calculado.
  update public.presupuestos set descuento = least(coalesce(nullif(p_datos->>'descuento', '')::numeric, 0), subtotal) where id = v_id;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- RLS y privilegios
-- -----------------------------------------------------------------------------
alter table public.reserva_items enable row level security;
alter table public.garantias     enable row level security;

create policy reserva_items_lectura on public.reserva_items for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.ver')));
create policy reserva_items_alta on public.reserva_items for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'reservas.editar')) or (select public.tiene_permiso(organizacion_id, 'reservas.crear')));
create policy reserva_items_edicion on public.reserva_items for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.editar')))
  with check ((select public.tiene_permiso(organizacion_id, 'reservas.editar')));
create policy reserva_items_baja on public.reserva_items for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.editar')));
create trigger reserva_items_auditoria after insert or update or delete on public.reserva_items for each row execute function public.auditar();

-- Garantías: solo lectura; los cambios pasan por las funciones (que validan el permiso).
create policy garantias_lectura on public.garantias for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.ver')));

grant select, insert, update, delete on public.reserva_items to authenticated;
grant select on public.garantias to authenticated;
grant execute on function public.agregar_item_reserva(uuid, text, numeric, text, numeric, uuid, boolean, boolean, date),
  public.pedir_garantia(uuid, numeric), public.quitar_garantia(uuid), public.cobrar_garantia(uuid, date, text, text),
  public.devolver_garantia(uuid, date, numeric, text, text), public.total_items_reserva(uuid) to authenticated;
revoke execute on function public.generar_recordatorios_garantias() from public, anon, authenticated;

do $$
begin
  perform cron.schedule('festy_recordatorios_garantias', '5 12 * * *', 'select public.generar_recordatorios_garantias()');
exception when others then
  raise warning 'pg_cron no disponible (%): programar generar_recordatorios_garantias externamente.', sqlerrm;
end $$;
