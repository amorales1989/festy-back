-- =============================================================================
-- Festy · Migración 3: clientes, reservas, agenda (ocupaciones y bloqueos),
-- cobros, gastos y tareas.
--
-- Anti-superposición: cada reserva/bloqueo genera "ocupaciones" por espacio con
-- el rango real ocupado (evento + preparación/montaje antes + desmontaje/limpieza
-- después). Una restricción EXCLUDE con GiST impide que dos ocupaciones
-- bloqueantes del mismo espacio se superpongan, incluso con transacciones
-- concurrentes. La validación previa en el trigger solo existe para devolver un
-- mensaje claro; la garantía la da la restricción.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Clientes
-- -----------------------------------------------------------------------------
create table public.clientes (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  tipo            text not null default 'persona' check (tipo in ('persona','empresa')),
  nombre          text not null check (length(trim(nombre)) between 2 and 160),
  documento       text,
  email           text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  telefono        text,
  direccion       text,
  origen          text check (origen in ('whatsapp','instagram','facebook','web','recomendacion','llamada','presencial','otro')),
  notas           text,
  es_ejemplo      boolean not null default false,
  busqueda        text generated always as (
                    public.normalizar(nombre || ' ' || coalesce(documento,'') || ' ' || coalesce(email,'') || ' ' || coalesce(telefono,''))
                  ) stored,
  creado_por      uuid references auth.users(id) on delete set null,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id)
);
create index clientes_org_idx on public.clientes (organizacion_id, nombre);
create index clientes_busqueda_idx on public.clientes using gin (busqueda extensions.gin_trgm_ops);
create trigger clientes_actualizado before update on public.clientes for each row execute function public.tocar_actualizado();

-- -----------------------------------------------------------------------------
-- Reservas
-- -----------------------------------------------------------------------------
create type public.estado_reserva as enum ('consulta','tentativa','senada','confirmada','finalizada','cancelada');
create type public.estado_contrato as enum ('no_requerido','pendiente','enviado','firmado');

alter table public.organizaciones add column ultimo_numero_reserva int not null default 0;

create table public.reservas (
  id                 uuid primary key default gen_random_uuid(),
  organizacion_id    uuid not null references public.organizaciones(id) on delete cascade,
  numero             int not null,
  sucursal_id        uuid not null,
  cliente_id         uuid not null,
  titulo             text not null check (length(trim(titulo)) between 2 and 160),
  tipo_evento        text not null default 'otro'
                       check (tipo_evento in ('casamiento','quince','cumpleanos','infantil','corporativo','egresados',
                                              'bautismo','comunion','aniversario','conferencia','otro')),
  estado             public.estado_reserva not null default 'consulta',
  inicio             timestamptz not null,
  fin                timestamptz not null,
  invitados          int check (invitados is null or invitados between 1 and 100000),
  responsable_id     uuid references auth.users(id) on delete set null,
  vence_tentativa_at timestamptz,
  contrato_estado    public.estado_contrato not null default 'pendiente',
  precio_total       numeric(14,2) not null default 0 check (precio_total >= 0),
  notas              text,
  motivo_cancelacion text,
  cancelada_at       timestamptz,
  es_ejemplo         boolean not null default false,
  creado_por         uuid references auth.users(id) on delete set null,
  creado_at          timestamptz not null default now(),
  actualizado_at     timestamptz not null default now(),
  unique (organizacion_id, id),
  unique (organizacion_id, numero),
  check (fin > inicio),
  check (fin - inicio <= interval '15 days'),
  foreign key (organizacion_id, sucursal_id) references public.sucursales(organizacion_id, id),
  foreign key (organizacion_id, cliente_id)  references public.clientes(organizacion_id, id)
);
create index reservas_org_inicio_idx on public.reservas (organizacion_id, inicio);
create index reservas_org_estado_idx on public.reservas (organizacion_id, estado);
create index reservas_cliente_idx on public.reservas (cliente_id);
create index reservas_tentativas_idx on public.reservas (vence_tentativa_at) where estado = 'tentativa';
create trigger reservas_actualizado before update on public.reservas for each row execute function public.tocar_actualizado();

-- ¿Un rango ocupa el día local indicado? Un evento nocturno que termina en la
-- madrugada (antes del mediodía) no ocupa el día siguiente: se considera del
-- día en que empieza. Se usa en disponibilidad y ocupación del panel.
create or replace function public.ocupa_dia(p_rango tstzrange, p_dia date, p_tz text)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select p_rango && tstzrange(p_dia::timestamp at time zone p_tz, (p_dia + 1)::timestamp at time zone p_tz, '[)')
     and (lower(p_rango) >= p_dia::timestamp at time zone p_tz
          or upper(p_rango) > (p_dia::timestamp + interval '12 hours') at time zone p_tz)
$$;

create or replace function public.estado_bloquea(e public.estado_reserva)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select e in ('tentativa','senada','confirmada','finalizada')
$$;

-- Número correlativo por organización y fechas derivadas del estado.
create or replace function public.reservas_antes_de_guardar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_horas int;
begin
  if tg_op = 'INSERT' then
    update public.organizaciones set ultimo_numero_reserva = ultimo_numero_reserva + 1
     where id = new.organizacion_id returning ultimo_numero_reserva into new.numero;
    new.creado_por := coalesce(new.creado_por, auth.uid());
  else
    new.numero := old.numero;
    new.organizacion_id := old.organizacion_id;
    new.creado_por := old.creado_por;
  end if;

  if new.estado = 'tentativa' and new.vence_tentativa_at is null then
    select horas_vencimiento_tentativa into v_horas from public.organizaciones where id = new.organizacion_id;
    new.vence_tentativa_at := now() + make_interval(hours => v_horas);
  elsif new.estado <> 'tentativa' then
    new.vence_tentativa_at := null;
  end if;

  if new.estado = 'cancelada' and (tg_op = 'INSERT' or old.estado <> 'cancelada') then
    new.cancelada_at := now();
  elsif new.estado <> 'cancelada' then
    new.cancelada_at := null;
  end if;

  return new;
end $$;
create trigger reservas_antes before insert or update on public.reservas
  for each row execute function public.reservas_antes_de_guardar();

-- Espacios asignados a la reserva, con tiempos operativos (copiados del espacio
-- al asignarlo y editables por reserva).
create table public.reserva_espacios (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  reserva_id      uuid not null,
  espacio_id      uuid not null,
  antes_min       int not null check (antes_min between 0 and 4320),
  despues_min     int not null check (despues_min between 0 and 4320),
  unique (reserva_id, espacio_id),
  unique (organizacion_id, id),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete cascade,
  foreign key (organizacion_id, espacio_id) references public.espacios(organizacion_id, id)
);
create index reserva_espacios_espacio_idx on public.reserva_espacios (espacio_id);

create or replace function public.reserva_espacios_antes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_esp public.espacios; v_suc uuid;
begin
  select * into v_esp from public.espacios where id = new.espacio_id;
  select sucursal_id into v_suc from public.reservas where id = new.reserva_id;
  if v_esp.sucursal_id <> v_suc then
    raise exception 'El espacio "%" no pertenece a la sucursal de la reserva.', v_esp.nombre using errcode = '23514';
  end if;
  if tg_op = 'INSERT' and not v_esp.activo then
    raise exception 'El espacio "%" está inactivo.', v_esp.nombre using errcode = '23514';
  end if;
  if new.antes_min is null then new.antes_min := v_esp.preparacion_min + v_esp.montaje_min; end if;
  if new.despues_min is null then new.despues_min := v_esp.desmontaje_min + v_esp.limpieza_min; end if;
  return new;
end $$;
create trigger reserva_espacios_antes before insert or update on public.reserva_espacios
  for each row execute function public.reserva_espacios_antes();

-- -----------------------------------------------------------------------------
-- Bloqueos de agenda
-- -----------------------------------------------------------------------------
create table public.bloqueos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  espacio_id      uuid not null,
  inicio          timestamptz not null,
  fin             timestamptz not null,
  tipo            text not null default 'otro' check (tipo in ('mantenimiento','privado','feriado','obra','otro')),
  motivo          text,
  creado_por      uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  check (fin > inicio),
  check (fin - inicio <= interval '366 days'),
  unique (organizacion_id, id),
  foreign key (organizacion_id, espacio_id) references public.espacios(organizacion_id, id) on delete cascade
);

-- -----------------------------------------------------------------------------
-- Ocupaciones (derivadas; nunca se escriben desde el cliente)
-- -----------------------------------------------------------------------------
create table public.ocupaciones (
  id                  uuid primary key default gen_random_uuid(),
  organizacion_id     uuid not null references public.organizaciones(id) on delete cascade,
  espacio_id          uuid not null references public.espacios(id) on delete cascade,
  reserva_espacio_id  uuid unique references public.reserva_espacios(id) on delete cascade,
  bloqueo_id          uuid unique references public.bloqueos(id) on delete cascade,
  rango               tstzrange not null,
  bloqueante          boolean not null,
  check (num_nonnulls(reserva_espacio_id, bloqueo_id) = 1),
  check (not isempty(rango)),
  constraint ocupaciones_sin_superposicion
    exclude using gist (espacio_id with =, rango with &&) where (bloqueante)
);
create index ocupaciones_org_rango_idx on public.ocupaciones using gist (organizacion_id, rango);

-- Inserta/actualiza la ocupación verificando conflictos con un mensaje legible.
create or replace function public.upsert_ocupacion(
  p_org uuid, p_espacio uuid, p_rango tstzrange, p_bloqueante boolean,
  p_reserva_espacio uuid, p_bloqueo uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_conf record;
  v_tz text;
  v_espacio text;
begin
  if p_bloqueante then
    select o.rango, r.numero, r.titulo, b.motivo, b.tipo
      into v_conf
      from public.ocupaciones o
      left join public.reserva_espacios re on re.id = o.reserva_espacio_id
      left join public.reservas r on r.id = re.reserva_id
      left join public.bloqueos b on b.id = o.bloqueo_id
     where o.espacio_id = p_espacio and o.bloqueante and o.rango && p_rango
       and (p_reserva_espacio is null or o.reserva_espacio_id is distinct from p_reserva_espacio)
       and (p_bloqueo is null or o.bloqueo_id is distinct from p_bloqueo)
     limit 1;
    if found then
      select zona_horaria into v_tz from public.organizaciones where id = p_org;
      select nombre into v_espacio from public.espacios where id = p_espacio;
      raise exception 'El espacio "%" ya está ocupado del % al % por %.',
        v_espacio,
        to_char(lower(v_conf.rango) at time zone v_tz, 'DD/MM/YYYY HH24:MI'),
        to_char(upper(v_conf.rango) at time zone v_tz, 'DD/MM/YYYY HH24:MI'),
        case when v_conf.numero is not null then format('la reserva #%s "%s"', v_conf.numero, v_conf.titulo)
             else format('un bloqueo (%s)', coalesce(nullif(v_conf.motivo, ''), v_conf.tipo)) end
        using errcode = '23P01', hint = 'CONFLICTO_AGENDA';
    end if;
  end if;

  if p_reserva_espacio is not null then
    insert into public.ocupaciones (organizacion_id, espacio_id, reserva_espacio_id, rango, bloqueante)
    values (p_org, p_espacio, p_reserva_espacio, p_rango, p_bloqueante)
    on conflict (reserva_espacio_id) do update
      set espacio_id = excluded.espacio_id, rango = excluded.rango, bloqueante = excluded.bloqueante;
  else
    insert into public.ocupaciones (organizacion_id, espacio_id, bloqueo_id, rango, bloqueante)
    values (p_org, p_espacio, p_bloqueo, p_rango, p_bloqueante)
    on conflict (bloqueo_id) do update
      set espacio_id = excluded.espacio_id, rango = excluded.rango, bloqueante = excluded.bloqueante;
  end if;
end $$;

create or replace function public.sincronizar_ocupaciones_reserva(p_reserva uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_r public.reservas;
  v_re record;
begin
  select * into v_r from public.reservas where id = p_reserva;
  if not found then return; end if;
  for v_re in
    select re.*, e.duracion_minima_min, e.nombre as espacio_nombre
      from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id
     where re.reserva_id = p_reserva
     order by re.espacio_id  -- orden estable para evitar interbloqueos
  loop
    if public.estado_bloquea(v_r.estado)
       and v_r.fin - v_r.inicio < make_interval(mins => v_re.duracion_minima_min) then
      raise exception 'La duración mínima para "%" es de % minutos.', v_re.espacio_nombre, v_re.duracion_minima_min
        using errcode = '23514';
    end if;
    perform public.upsert_ocupacion(
      v_r.organizacion_id, v_re.espacio_id,
      tstzrange(v_r.inicio - make_interval(mins => v_re.antes_min),
                v_r.fin    + make_interval(mins => v_re.despues_min), '[)'),
      public.estado_bloquea(v_r.estado), v_re.id, null);
  end loop;
end $$;

create or replace function public.reservas_despues_de_guardar()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.sucursal_id <> old.sucursal_id and exists (
       select 1 from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id
        where re.reserva_id = new.id and e.sucursal_id <> new.sucursal_id) then
    raise exception 'Quitá los espacios de la sucursal anterior antes de cambiar la sucursal.' using errcode = '23514';
  end if;
  if tg_op = 'INSERT' or new.inicio <> old.inicio or new.fin <> old.fin or new.estado <> old.estado then
    perform public.sincronizar_ocupaciones_reserva(new.id);
  end if;
  return null;
end $$;
create trigger reservas_despues after insert or update on public.reservas
  for each row execute function public.reservas_despues_de_guardar();

create or replace function public.reserva_espacios_despues()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.sincronizar_ocupaciones_reserva(new.reserva_id);
  return null;
end $$;
create trigger reserva_espacios_despues after insert or update on public.reserva_espacios
  for each row execute function public.reserva_espacios_despues();
-- En DELETE la ocupación se elimina por ON DELETE CASCADE.

create or replace function public.bloqueos_despues()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.upsert_ocupacion(new.organizacion_id, new.espacio_id,
    tstzrange(new.inicio, new.fin, '[)'), true, null, new.id);
  return null;
end $$;
create trigger bloqueos_despues after insert or update on public.bloqueos
  for each row execute function public.bloqueos_despues();

-- Capacidad: se valida al final de la transacción para permitir crear la
-- reserva y asignar sus espacios en pasos sucesivos.
create or replace function public.verificar_capacidad_reserva()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_reserva uuid;
  v_inv int; v_cap int; v_estado public.estado_reserva;
begin
  if tg_table_name = 'reservas' then
    v_reserva := new.id;
  else
    v_reserva := (to_jsonb(new)->>'reserva_id')::uuid;
  end if;
  select invitados, estado into v_inv, v_estado from public.reservas where id = v_reserva;
  if v_inv is null or v_estado = 'cancelada' then return null; end if;
  select coalesce(sum(e.capacidad_maxima), 0) into v_cap
    from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id
   where re.reserva_id = v_reserva;
  if v_cap > 0 and v_inv > v_cap then
    raise exception 'La cantidad de invitados (%) supera la capacidad de los espacios elegidos (%).', v_inv, v_cap
      using errcode = '23514';
  end if;
  return null;
end $$;
create constraint trigger reservas_capacidad after insert or update of invitados on public.reservas
  deferrable initially deferred for each row execute function public.verificar_capacidad_reserva();
create constraint trigger reserva_espacios_capacidad after insert or update on public.reserva_espacios
  deferrable initially deferred for each row execute function public.verificar_capacidad_reserva();

-- Vence tentativas: vuelven a "consulta" y liberan la fecha.
create or replace function public.vencer_tentativas()
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update public.reservas
     set estado = 'consulta',
         notas = concat_ws(E'\n', notas, format('[%s] Reserva tentativa vencida automáticamente.', to_char(now(), 'DD/MM/YYYY HH24:MI')))
   where estado = 'tentativa' and vence_tentativa_at < now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.vencer_tentativas() from public, anon, authenticated;

-- Marca como finalizadas las reservas confirmadas/señadas cuyo evento terminó.
create or replace function public.finalizar_eventos_pasados()
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update public.reservas set estado = 'finalizada'
   where estado in ('confirmada','senada') and fin < now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.finalizar_eventos_pasados() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Cobros
-- -----------------------------------------------------------------------------
create table public.cuotas (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  reserva_id      uuid not null,
  concepto        text not null default 'Cuota',
  vencimiento     date not null,
  monto           numeric(14,2) not null check (monto > 0),
  creado_at       timestamptz not null default now(),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete cascade
);
create index cuotas_reserva_idx on public.cuotas (reserva_id, vencimiento);
create index cuotas_org_venc_idx on public.cuotas (organizacion_id, vencimiento);

create table public.pagos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  reserva_id      uuid not null,
  fecha           date not null,
  monto           numeric(14,2) not null check (monto > 0),
  medio           text not null default 'efectivo'
                    check (medio in ('efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro')),
  concepto        text not null default 'cuota' check (concepto in ('sena','cuota','saldo','extra')),
  referencia      text,
  notas           text,
  anulado         boolean not null default false,
  anulado_motivo  text,
  anulado_por     uuid references auth.users(id) on delete set null,
  anulado_at      timestamptz,
  registrado_por  uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete restrict
);
create index pagos_reserva_idx on public.pagos (reserva_id);
create index pagos_org_fecha_idx on public.pagos (organizacion_id, fecha) where not anulado;

-- Un cobro no se edita ni se borra: solo se anula, con motivo.
create or replace function public.proteger_pago()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.anulado then
    raise exception 'El cobro ya está anulado.' using errcode = '42501';
  end if;
  if (new.fecha, new.monto, new.medio, new.concepto, new.reserva_id, new.organizacion_id, new.registrado_por)
     is distinct from (old.fecha, old.monto, old.medio, old.concepto, old.reserva_id, old.organizacion_id, old.registrado_por) then
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
create trigger pagos_proteger before update on public.pagos for each row execute function public.proteger_pago();

-- -----------------------------------------------------------------------------
-- Gastos
-- -----------------------------------------------------------------------------
create table public.gastos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  sucursal_id     uuid,
  reserva_id      uuid,
  fecha           date not null,
  categoria       text not null default 'otro'
                    check (categoria in ('personal','catering','limpieza','mantenimiento','servicios','impuestos','alquiler','marketing','proveedores','otro')),
  descripcion     text not null check (length(trim(descripcion)) between 2 and 240),
  proveedor       text,
  monto           numeric(14,2) not null check (monto > 0),
  medio           text not null default 'efectivo'
                    check (medio in ('efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro')),
  es_ejemplo      boolean not null default false,
  registrado_por  uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  foreign key (organizacion_id, sucursal_id) references public.sucursales(organizacion_id, id) on delete set null (sucursal_id),
  foreign key (organizacion_id, reserva_id)  references public.reservas(organizacion_id, id) on delete set null (reserva_id)
);
create index gastos_org_fecha_idx on public.gastos (organizacion_id, fecha);

-- -----------------------------------------------------------------------------
-- Tareas
-- -----------------------------------------------------------------------------
create table public.tareas (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  reserva_id      uuid,
  titulo          text not null check (length(trim(titulo)) between 2 and 200),
  descripcion     text,
  vence_el        date,
  asignada_a      uuid references auth.users(id) on delete set null,
  estado          text not null default 'pendiente' check (estado in ('pendiente','en_curso','hecha')),
  prioridad       text not null default 'media' check (prioridad in ('baja','media','alta')),
  completada_at   timestamptz,
  es_ejemplo      boolean not null default false,
  creado_por      uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete cascade
);
create index tareas_org_estado_idx on public.tareas (organizacion_id, estado, vence_el);
create index tareas_asignada_idx on public.tareas (asignada_a) where estado <> 'hecha';
create trigger tareas_actualizado before update on public.tareas for each row execute function public.tocar_actualizado();

-- Quien no gestiona tareas solo puede cambiar el estado de las que tiene asignadas.
create or replace function public.tareas_antes()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and current_user in ('authenticated', 'anon')
     and not public.tiene_permiso(new.organizacion_id, 'tareas.gestionar')
     and (new.titulo, new.descripcion, new.vence_el, new.asignada_a, new.prioridad, new.reserva_id)
         is distinct from (old.titulo, old.descripcion, old.vence_el, old.asignada_a, old.prioridad, old.reserva_id) then
    raise exception 'Solo podés cambiar el estado de tus tareas.' using errcode = '42501';
  end if;
  if new.estado = 'hecha' and (tg_op = 'INSERT' or old.estado <> 'hecha') then
    new.completada_at := now();
  elsif new.estado <> 'hecha' then
    new.completada_at := null;
  end if;
  return new;
end $$;
create trigger tareas_antes before insert or update on public.tareas for each row execute function public.tareas_antes();

-- -----------------------------------------------------------------------------
-- Vistas de saldos (security_invoker: respetan la RLS del usuario)
-- -----------------------------------------------------------------------------
create view public.v_reservas_saldo with (security_invoker = true) as
select
  r.id as reserva_id,
  r.organizacion_id,
  r.precio_total,
  coalesce(p.pagado, 0)                          as pagado,
  greatest(r.precio_total - coalesce(p.pagado, 0), 0) as saldo,
  coalesce(c.total_cuotas, 0)                    as total_cuotas,
  greatest(coalesce(c.vencido_cuotas, 0) - coalesce(p.pagado, 0), 0) as vencido
from public.reservas r
join public.organizaciones o on o.id = r.organizacion_id
left join lateral (
  select sum(monto) as pagado from public.pagos where reserva_id = r.id and not anulado
) p on true
left join lateral (
  select sum(monto) as total_cuotas,
         sum(monto) filter (where vencimiento < (now() at time zone o.zona_horaria)::date) as vencido_cuotas
  from public.cuotas where reserva_id = r.id
) c on true;

-- Estado de cada cuota aplicando los cobros en orden de vencimiento (FIFO).
create view public.v_cuotas_estado with (security_invoker = true) as
with base as (
  select c.*,
         sum(c.monto) over (partition by c.reserva_id order by c.vencimiento, c.creado_at, c.id) as acumulado,
         coalesce((select sum(p.monto) from public.pagos p where p.reserva_id = c.reserva_id and not p.anulado), 0) as pagado_total
  from public.cuotas c
)
select b.id, b.organizacion_id, b.reserva_id, b.concepto, b.vencimiento, b.monto,
       least(b.monto, greatest(b.acumulado - b.pagado_total, 0)) as pendiente
from base b;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.clientes         enable row level security;
alter table public.reservas         enable row level security;
alter table public.reserva_espacios enable row level security;
alter table public.bloqueos         enable row level security;
alter table public.ocupaciones      enable row level security;
alter table public.cuotas           enable row level security;
alter table public.pagos            enable row level security;
alter table public.gastos           enable row level security;
alter table public.tareas           enable row level security;

create policy clientes_lectura on public.clientes for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'clientes.ver')));
create policy clientes_alta on public.clientes for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'clientes.gestionar')));
create policy clientes_edicion on public.clientes for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'clientes.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'clientes.gestionar')));
create policy clientes_baja on public.clientes for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'clientes.gestionar')));

create policy reservas_lectura on public.reservas for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.ver')));
create policy reservas_alta on public.reservas for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'reservas.crear')));
create policy reservas_edicion on public.reservas for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.editar'))
         or (select public.tiene_permiso(organizacion_id, 'reservas.cancelar'))
         or (select public.tiene_permiso(organizacion_id, 'contratos.gestionar')))
  with check ((select public.es_miembro(organizacion_id)));
create policy reservas_baja on public.reservas for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.eliminar')));

-- Permisos finos sobre campos. SECURITY INVOKER: solo aplica a cambios hechos
-- directamente por usuarios de la API; las RPC SECURITY DEFINER validan su permiso.
create or replace function public.reservas_campos_por_permiso()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if new.estado = 'cancelada' and (tg_op = 'INSERT' or old.estado <> 'cancelada')
     and not public.tiene_permiso(new.organizacion_id, 'reservas.cancelar') then
    raise exception 'No tenés permiso para cancelar reservas.' using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    return new;
  end if;
  if new.contrato_estado is distinct from old.contrato_estado
     and not public.tiene_permiso(new.organizacion_id, 'contratos.gestionar') then
    raise exception 'No tenés permiso para cambiar el estado del contrato.' using errcode = '42501';
  end if;
  if not public.tiene_permiso(new.organizacion_id, 'reservas.editar') then
    if (new.sucursal_id, new.cliente_id, new.titulo, new.tipo_evento, new.inicio, new.fin, new.invitados,
        new.responsable_id, new.precio_total, new.notas)
       is distinct from
       (old.sucursal_id, old.cliente_id, old.titulo, old.tipo_evento, old.inicio, old.fin, old.invitados,
        old.responsable_id, old.precio_total, old.notas)
       or (new.estado <> old.estado and new.estado <> 'cancelada') then
      raise exception 'No tenés permiso para editar reservas.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger reservas_campos before insert or update on public.reservas
  for each row execute function public.reservas_campos_por_permiso();

create policy reserva_espacios_lectura on public.reserva_espacios for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.ver'))
         or (select public.tiene_permiso(organizacion_id, 'calendario.ver')));
create policy reserva_espacios_alta on public.reserva_espacios for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'reservas.crear'))
              or (select public.tiene_permiso(organizacion_id, 'reservas.editar')));
create policy reserva_espacios_edicion on public.reserva_espacios for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.editar')))
  with check ((select public.tiene_permiso(organizacion_id, 'reservas.editar')));
create policy reserva_espacios_baja on public.reserva_espacios for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'reservas.editar')));

create policy bloqueos_lectura on public.bloqueos for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'calendario.ver')));
create policy bloqueos_alta on public.bloqueos for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'bloqueos.gestionar')));
create policy bloqueos_edicion on public.bloqueos for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'bloqueos.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'bloqueos.gestionar')));
create policy bloqueos_baja on public.bloqueos for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'bloqueos.gestionar')));

-- Ocupaciones: solo lectura. Las escriben los triggers.
create policy ocupaciones_lectura on public.ocupaciones for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'calendario.ver')));

create policy cuotas_lectura on public.cuotas for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.ver')));
create policy cuotas_alta on public.cuotas for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'pagos.registrar')));
create policy cuotas_edicion on public.cuotas for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.registrar')))
  with check ((select public.tiene_permiso(organizacion_id, 'pagos.registrar')));
create policy cuotas_baja on public.cuotas for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.registrar')));

create policy pagos_lectura on public.pagos for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.ver')));
create policy pagos_alta on public.pagos for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'pagos.registrar')) and not anulado);
create policy pagos_anulacion on public.pagos for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'pagos.anular')))
  with check ((select public.tiene_permiso(organizacion_id, 'pagos.anular')));

create policy gastos_lectura on public.gastos for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'gastos.ver')));
create policy gastos_alta on public.gastos for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'gastos.gestionar')));
create policy gastos_edicion on public.gastos for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'gastos.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'gastos.gestionar')));
create policy gastos_baja on public.gastos for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'gastos.gestionar')));

create policy tareas_lectura on public.tareas for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'tareas.ver')));
create policy tareas_alta on public.tareas for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'tareas.gestionar')));
create policy tareas_edicion on public.tareas for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'tareas.gestionar'))
         or (asignada_a = (select auth.uid()) and (select public.es_miembro(organizacion_id))))
  with check ((select public.es_miembro(organizacion_id)));
create policy tareas_baja on public.tareas for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'tareas.gestionar')));
