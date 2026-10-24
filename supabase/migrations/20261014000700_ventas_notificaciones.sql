-- =============================================================================
-- Festy · Migración 7: herramientas de venta y notificaciones.
--   * Marca del salón para documentos (logo, color, condiciones).
--   * Catálogo de servicios (paquetes, servicios y adicionales).
--   * Presupuestos con ítems, plan de pagos, vigencia y conversión a evento.
--   * Entrevistas con clientes (reuniones de venta).
--   * Comprobantes de pago con numeración correlativa por organización.
--   * Notificaciones internas + dispositivos para push (Android/iOS/web).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Marca y contadores en la organización
-- -----------------------------------------------------------------------------
alter table public.organizaciones
  add column logo text check (logo is null or (logo ~ '^data:image/(png|jpeg);base64,' and length(logo) <= 400000)),
  add column color_marca text not null default '#7c3aed' check (color_marca ~ '^#[0-9a-fA-F]{6}$'),
  add column direccion text,
  add column condiciones_presupuesto text default
    'La fecha queda reservada al abonar la seña. La seña no es reembolsable. El saldo debe cancelarse antes del evento según el plan de pagos. Los precios pueden actualizarse si el presupuesto vence.',
  add column validez_presupuesto_dias int not null default 15 check (validez_presupuesto_dias between 1 and 180),
  add column ultimo_numero_presupuesto int not null default 0,
  add column ultimo_numero_comprobante int not null default 0;

-- Los contadores solo los mueven funciones internas.
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
    or new.ultimo_numero_comprobante is distinct from old.ultimo_numero_comprobante) then
    raise exception 'Estos datos de la cuenta solo pueden cambiarse desde la sección Plan o Baja.' using errcode = '42501';
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Permisos nuevos y asignación a roles existentes y a la plantilla
-- -----------------------------------------------------------------------------
insert into public.permisos (clave, modulo, descripcion, orden) values
  ('catalogo.gestionar',     'Ventas', 'Crear y editar el catálogo de servicios y precios', 55),
  ('presupuestos.ver',       'Ventas', 'Ver presupuestos', 56),
  ('presupuestos.gestionar', 'Ventas', 'Crear, enviar y aceptar presupuestos', 57),
  ('entrevistas.ver',        'Ventas', 'Ver entrevistas con clientes', 58),
  ('entrevistas.gestionar',  'Ventas', 'Agendar y editar entrevistas', 59);

update public.roles_plantilla set permisos = permisos || case clave
    when 'propietario'   then array['catalogo.gestionar','presupuestos.ver','presupuestos.gestionar','entrevistas.ver','entrevistas.gestionar']
    when 'administrador' then array['catalogo.gestionar','presupuestos.ver','presupuestos.gestionar','entrevistas.ver','entrevistas.gestionar']
    when 'recepcion'     then array['presupuestos.ver','presupuestos.gestionar','entrevistas.ver','entrevistas.gestionar']
    when 'vendedor'      then array['presupuestos.ver','presupuestos.gestionar','entrevistas.ver','entrevistas.gestionar']
    when 'finanzas'      then array['presupuestos.ver']
    when 'coordinador'   then array['presupuestos.ver','entrevistas.ver']
    else array[]::text[] end;

insert into public.rol_permisos (organizacion_id, rol_id, permiso)
select r.organizacion_id, r.id, p
from public.roles r
join public.roles_plantilla rp on rp.clave = r.clave
cross join lateral unnest(rp.permisos) p
where r.es_sistema
  and p in ('catalogo.gestionar','presupuestos.ver','presupuestos.gestionar','entrevistas.ver','entrevistas.gestionar')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Catálogo de servicios
-- -----------------------------------------------------------------------------
create table public.servicios (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  nombre          text not null check (length(trim(nombre)) between 2 and 160),
  descripcion     text,
  tipo            text not null default 'servicio' check (tipo in ('paquete','servicio','adicional')),
  categoria       text not null default 'otro'
                    check (categoria in ('salon','catering','bebidas','musica','decoracion','ambientacion','fotografia','animacion','mobiliario','personal','otro')),
  unidad          text not null default 'evento' check (unidad in ('evento','persona','hora','unidad')),
  precio          numeric(14,2) not null check (precio >= 0),
  costo           numeric(14,2) check (costo is null or costo >= 0),
  activo          boolean not null default true,
  es_ejemplo      boolean not null default false,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id)
);
create index servicios_org_idx on public.servicios (organizacion_id, tipo, nombre);
create trigger servicios_actualizado before update on public.servicios for each row execute function public.tocar_actualizado();

-- -----------------------------------------------------------------------------
-- Presupuestos
-- -----------------------------------------------------------------------------
create table public.presupuestos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  numero          int not null,
  cliente_id      uuid not null,
  reserva_id      uuid,
  espacio_id      uuid,
  titulo          text not null check (length(trim(titulo)) between 2 and 160),
  tipo_evento     text not null default 'otro',
  fecha_evento    date,
  hora_inicio     time,
  hora_fin        time,
  invitados       int check (invitados is null or invitados between 1 and 100000),
  estado          text not null default 'borrador' check (estado in ('borrador','enviado','aceptado','rechazado','vencido')),
  valido_hasta    date not null,
  subtotal        numeric(14,2) not null default 0,
  descuento       numeric(14,2) not null default 0 check (descuento >= 0),
  total           numeric(14,2) not null default 0,
  sena_porcentaje numeric(5,2) not null default 30 check (sena_porcentaje between 0 and 100),
  cantidad_cuotas int not null default 2 check (cantidad_cuotas between 0 and 24),
  condiciones     text,
  notas           text,
  enviado_at      timestamptz,
  respondido_at   timestamptz,
  es_ejemplo      boolean not null default false,
  creado_por      uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id),
  unique (organizacion_id, numero),
  check (descuento <= subtotal or subtotal = 0),
  foreign key (organizacion_id, cliente_id) references public.clientes(organizacion_id, id),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete set null (reserva_id),
  foreign key (organizacion_id, espacio_id) references public.espacios(organizacion_id, id) on delete set null (espacio_id)
);
create index presupuestos_org_idx on public.presupuestos (organizacion_id, estado, creado_at desc);
create index presupuestos_cliente_idx on public.presupuestos (cliente_id);
create trigger presupuestos_actualizado before update on public.presupuestos for each row execute function public.tocar_actualizado();

create table public.presupuesto_items (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  presupuesto_id  uuid not null,
  servicio_id     uuid,
  descripcion     text not null check (length(trim(descripcion)) between 1 and 300),
  cantidad        numeric(10,2) not null default 1 check (cantidad > 0),
  unidad          text not null default 'evento' check (unidad in ('evento','persona','hora','unidad')),
  precio_unitario numeric(14,2) not null check (precio_unitario >= 0),
  orden           int not null default 0,
  foreign key (organizacion_id, presupuesto_id) references public.presupuestos(organizacion_id, id) on delete cascade,
  foreign key (organizacion_id, servicio_id) references public.servicios(organizacion_id, id) on delete set null (servicio_id)
);
create index presupuesto_items_idx on public.presupuesto_items (presupuesto_id, orden);

create or replace function public.presupuestos_antes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_dias int;
begin
  if tg_op = 'INSERT' then
    update public.organizaciones set ultimo_numero_presupuesto = ultimo_numero_presupuesto + 1
     where id = new.organizacion_id
    returning ultimo_numero_presupuesto, validez_presupuesto_dias into new.numero, v_dias;
    if new.valido_hasta is null then
      new.valido_hasta := (now() at time zone (select zona_horaria from public.organizaciones where id = new.organizacion_id))::date + v_dias;
    end if;
    if new.condiciones is null then
      select condiciones_presupuesto into new.condiciones from public.organizaciones where id = new.organizacion_id;
    end if;
  else
    new.numero := old.numero;
    new.organizacion_id := old.organizacion_id;
  end if;
  new.total := greatest(new.subtotal - new.descuento, 0);
  if new.estado = 'enviado' and (tg_op = 'INSERT' or old.estado <> 'enviado') then new.enviado_at := now(); end if;
  if new.estado in ('aceptado','rechazado') and (tg_op = 'INSERT' or old.estado not in ('aceptado','rechazado')) then new.respondido_at := now(); end if;
  return new;
end $$;
create trigger presupuestos_antes before insert or update on public.presupuestos
  for each row execute function public.presupuestos_antes();

-- El subtotal siempre es la suma de los ítems.
create or replace function public.recalcular_presupuesto()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid := coalesce(new.presupuesto_id, old.presupuesto_id);
begin
  update public.presupuestos p
     set subtotal = coalesce((select sum(round(i.cantidad * i.precio_unitario, 2)) from public.presupuesto_items i where i.presupuesto_id = v_id), 0),
         descuento = least(p.descuento, coalesce((select sum(round(i.cantidad * i.precio_unitario, 2)) from public.presupuesto_items i where i.presupuesto_id = v_id), 0))
   where p.id = v_id;
  return null;
end $$;
create trigger presupuesto_items_recalcular after insert or update or delete on public.presupuesto_items
  for each row execute function public.recalcular_presupuesto();

-- Vence presupuestos enviados sin respuesta.
create or replace function public.vencer_presupuestos()
returns int language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update public.presupuestos p set estado = 'vencido'
    from public.organizaciones o
   where o.id = p.organizacion_id and p.estado in ('borrador','enviado')
     and p.valido_hasta < (now() at time zone o.zona_horaria)::date;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Acepta el presupuesto y crea (o actualiza) el evento con su plan de cuotas.
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

-- -----------------------------------------------------------------------------
-- Entrevistas
-- -----------------------------------------------------------------------------
create table public.entrevistas (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  cliente_id      uuid,
  contacto_nombre text,
  contacto_telefono text,
  inicio          timestamptz not null,
  duracion_min    int not null default 45 check (duracion_min between 10 and 480),
  modalidad       text not null default 'presencial' check (modalidad in ('presencial','videollamada','telefono')),
  sucursal_id     uuid,
  enlace          text,
  motivo          text,
  asignada_a      uuid references auth.users(id) on delete set null,
  estado          text not null default 'programada' check (estado in ('programada','realizada','cancelada','no_asistio')),
  notas           text,
  reserva_id      uuid,
  presupuesto_id  uuid,
  es_ejemplo      boolean not null default false,
  creado_por      uuid references auth.users(id) on delete set null default auth.uid(),
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  check (cliente_id is not null or length(trim(coalesce(contacto_nombre, ''))) >= 2),
  foreign key (organizacion_id, cliente_id) references public.clientes(organizacion_id, id) on delete cascade,
  foreign key (organizacion_id, sucursal_id) references public.sucursales(organizacion_id, id) on delete set null (sucursal_id),
  foreign key (organizacion_id, reserva_id) references public.reservas(organizacion_id, id) on delete set null (reserva_id),
  foreign key (organizacion_id, presupuesto_id) references public.presupuestos(organizacion_id, id) on delete set null (presupuesto_id)
);
create index entrevistas_org_inicio_idx on public.entrevistas (organizacion_id, inicio);
create trigger entrevistas_actualizado before update on public.entrevistas for each row execute function public.tocar_actualizado();

-- -----------------------------------------------------------------------------
-- Comprobantes de pago: número correlativo por organización
-- -----------------------------------------------------------------------------
alter table public.pagos add column numero_comprobante int;

with numerados as (
  select id, row_number() over (partition by organizacion_id order by creado_at, id) as n from public.pagos
)
update public.pagos p set numero_comprobante = n.n from numerados n where n.id = p.id;
update public.organizaciones o set ultimo_numero_comprobante = coalesce((select max(numero_comprobante) from public.pagos where organizacion_id = o.id), 0);

alter table public.pagos alter column numero_comprobante set not null;
alter table public.pagos add constraint pagos_comprobante_unico unique (organizacion_id, numero_comprobante);

create or replace function public.pagos_numerar()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.organizaciones set ultimo_numero_comprobante = ultimo_numero_comprobante + 1
   where id = new.organizacion_id returning ultimo_numero_comprobante into new.numero_comprobante;
  return new;
end $$;
create trigger pagos_numerar before insert on public.pagos for each row execute function public.pagos_numerar();

create or replace function public.proteger_pago()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.anulado then
    raise exception 'El cobro ya está anulado.' using errcode = '42501';
  end if;
  if (new.fecha, new.monto, new.medio, new.concepto, new.reserva_id, new.organizacion_id, new.registrado_por, new.numero_comprobante)
     is distinct from (old.fecha, old.monto, old.medio, old.concepto, old.reserva_id, old.organizacion_id, old.registrado_por, old.numero_comprobante) then
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

-- -----------------------------------------------------------------------------
-- Notificaciones y dispositivos (push)
-- -----------------------------------------------------------------------------
create table public.notificaciones (
  id              bigint generated always as identity primary key,
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  usuario_id      uuid not null references auth.users(id) on delete cascade,
  tipo            text not null,
  titulo          text not null,
  cuerpo          text,
  url             text,
  -- evita duplicar recordatorios (p. ej. 'cuota:<id>:<fecha>')
  clave           text,
  leida_at        timestamptz,
  push_enviada_at timestamptz,
  creado_at       timestamptz not null default now(),
  unique (usuario_id, clave)
);
create index notificaciones_usuario_idx on public.notificaciones (usuario_id, creado_at desc);
create index notificaciones_push_pendiente_idx on public.notificaciones (creado_at) where push_enviada_at is null;

create table public.dispositivos (
  id             uuid primary key default gen_random_uuid(),
  usuario_id     uuid not null references auth.users(id) on delete cascade,
  token          text not null unique,
  plataforma     text not null check (plataforma in ('android','ios','web')),
  creado_at      timestamptz not null default now(),
  actualizado_at timestamptz not null default now()
);
create index dispositivos_usuario_idx on public.dispositivos (usuario_id);

-- Registra el token del dispositivo para el usuario actual (un token pertenece a un solo usuario).
create or replace function public.registrar_dispositivo(p_token text, p_plataforma text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Necesitás iniciar sesión.' using errcode = '28000'; end if;
  if length(coalesce(p_token, '')) < 20 then raise exception 'Token inválido.' using errcode = '22023'; end if;
  insert into public.dispositivos (usuario_id, token, plataforma) values (auth.uid(), p_token, p_plataforma)
  on conflict (token) do update set usuario_id = excluded.usuario_id, plataforma = excluded.plataforma, actualizado_at = now();
end $$;

create or replace function public.quitar_dispositivo(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from public.dispositivos where token = p_token and usuario_id = auth.uid()
$$;

create or replace function public.usuarios_con_permiso(p_org uuid, p_permiso text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select m.usuario_id from public.membresias m join public.rol_permisos rp on rp.rol_id = m.rol_id
   where m.organizacion_id = p_org and m.activo and rp.permiso = p_permiso
$$;

-- "$ 1.500.000,50" sin depender de la configuración regional del servidor.
create or replace function public.formato_ars(p numeric)
returns text language sql immutable parallel safe set search_path = '' as $$
  select '$ ' || translate(to_char(p, 'FM999,999,999,990.00'), ',.', '.,')
$$;

create or replace function public.notificar(p_org uuid, p_usuarios uuid[], p_tipo text, p_titulo text, p_cuerpo text, p_url text, p_clave text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select p_org, u, p_tipo, p_titulo, p_cuerpo, p_url, case when p_clave is null then null else p_clave end
    from unnest(p_usuarios) u
   where u is not null and u is distinct from auth.uid()  -- no se notifica a quien hizo la acción
  on conflict (usuario_id, clave) do nothing;
end $$;

-- Cobro registrado → avisa a quienes ven cobros.
create or replace function public.notificar_pago()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_r public.reservas;
begin
  select * into v_r from public.reservas where id = new.reserva_id;
  if v_r.es_ejemplo then return null; end if;
  perform public.notificar(new.organizacion_id,
    array(select public.usuarios_con_permiso(new.organizacion_id, 'pagos.ver')), 'pago',
    format('Cobro registrado: %s', public.formato_ars(new.monto)),
    format('%s · #%s %s', case new.concepto when 'sena' then 'Seña' when 'saldo' then 'Saldo' when 'extra' then 'Extra' else 'Cuota' end, v_r.numero, v_r.titulo),
    format('/reservas/%s', new.reserva_id));
  return null;
end $$;
create trigger pagos_notificar after insert on public.pagos for each row execute function public.notificar_pago();

-- Evento asignado a un responsable.
create or replace function public.notificar_responsable()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.responsable_id is not null and not new.es_ejemplo
     and (tg_op = 'INSERT' or new.responsable_id is distinct from old.responsable_id) then
    perform public.notificar(new.organizacion_id, array[new.responsable_id], 'reserva',
      'Te asignaron un evento', format('#%s %s', new.numero, new.titulo), format('/reservas/%s', new.id));
  end if;
  return null;
end $$;
create trigger reservas_notificar after insert or update of responsable_id on public.reservas
  for each row execute function public.notificar_responsable();

-- Entrevista asignada.
create or replace function public.notificar_entrevista()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_tz text; v_nombre text;
begin
  if new.asignada_a is not null and not new.es_ejemplo and (tg_op = 'INSERT' or new.asignada_a is distinct from old.asignada_a) then
    select zona_horaria into v_tz from public.organizaciones where id = new.organizacion_id;
    select coalesce((select nombre from public.clientes where id = new.cliente_id), new.contacto_nombre) into v_nombre;
    perform public.notificar(new.organizacion_id, array[new.asignada_a], 'entrevista', 'Nueva entrevista asignada',
      format('%s · %s', v_nombre, to_char(new.inicio at time zone v_tz, 'DD/MM HH24:MI')), '/calendario?vista=lista');
  end if;
  return null;
end $$;
create trigger entrevistas_notificar after insert or update of asignada_a on public.entrevistas
  for each row execute function public.notificar_entrevista();

-- Presupuesto aceptado → avisa a quien lo creó.
create or replace function public.notificar_presupuesto()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado = 'aceptado' and old.estado <> 'aceptado' and not new.es_ejemplo then
    perform public.notificar(new.organizacion_id, array[new.creado_por], 'presupuesto',
      format('Presupuesto #%s aceptado', new.numero), new.titulo, format('/presupuestos/%s', new.id));
  end if;
  return null;
end $$;
create trigger presupuestos_notificar after update of estado on public.presupuestos
  for each row execute function public.notificar_presupuesto();

-- Recordatorios diarios (cuotas, entrevistas, fechas retenidas y tareas del día).
create or replace function public.generar_recordatorios()
returns int language plpgsql security definer set search_path = '' as $$
declare v_antes int; v_despues int;
begin
  select count(*) into v_antes from public.notificaciones;

  -- Cuotas que vencen hoy o mañana con saldo pendiente
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select c.organizacion_id, u, 'cuota',
         format('Cuota por cobrar: %s', public.formato_ars(c.pendiente)),
         format('#%s %s · vence %s', r.numero, r.titulo, to_char(c.vencimiento, 'DD/MM/YYYY')),
         format('/reservas/%s', r.id), format('cuota:%s:%s', c.id, c.vencimiento)
    from public.v_cuotas_estado c
    join public.reservas r on r.id = c.reserva_id
    join public.organizaciones o on o.id = c.organizacion_id
    cross join lateral public.usuarios_con_permiso(c.organizacion_id, 'pagos.ver') u
   where c.pendiente > 0 and r.estado <> 'cancelada' and not r.es_ejemplo
     and c.vencimiento between (now() at time zone o.zona_horaria)::date and (now() at time zone o.zona_horaria)::date + 1
  on conflict (usuario_id, clave) do nothing;

  -- Entrevistas de hoy
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select e.organizacion_id, coalesce(e.asignada_a, e.creado_por), 'entrevista',
         format('Hoy a las %s: entrevista', to_char(e.inicio at time zone o.zona_horaria, 'HH24:MI')),
         coalesce((select nombre from public.clientes where id = e.cliente_id), e.contacto_nombre),
         '/calendario?vista=lista', format('entrevista:%s', e.id)
    from public.entrevistas e join public.organizaciones o on o.id = e.organizacion_id
   where e.estado = 'programada' and not e.es_ejemplo and coalesce(e.asignada_a, e.creado_por) is not null
     and (e.inicio at time zone o.zona_horaria)::date = (now() at time zone o.zona_horaria)::date
  on conflict (usuario_id, clave) do nothing;

  -- Fechas retenidas que vencen en las próximas 24 h
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select r.organizacion_id, u, 'tentativa', 'Se libera una fecha retenida', format('#%s %s: pedí la seña', r.numero, r.titulo),
         format('/reservas/%s', r.id), format('tentativa:%s:%s', r.id, r.vence_tentativa_at::date)
    from public.reservas r
    cross join lateral (select coalesce(r.responsable_id, r.creado_por) as u) x
   where r.estado = 'tentativa' and not r.es_ejemplo and x.u is not null
     and r.vence_tentativa_at between now() and now() + interval '24 hours'
  on conflict (usuario_id, clave) do nothing;

  -- Tareas que vencen hoy
  insert into public.notificaciones (organizacion_id, usuario_id, tipo, titulo, cuerpo, url, clave)
  select t.organizacion_id, t.asignada_a, 'tarea', 'Tarea para hoy', t.titulo, '/tareas', format('tarea:%s:%s', t.id, t.vence_el)
    from public.tareas t join public.organizaciones o on o.id = t.organizacion_id
   where t.estado <> 'hecha' and t.asignada_a is not null and not t.es_ejemplo
     and t.vence_el = (now() at time zone o.zona_horaria)::date
  on conflict (usuario_id, clave) do nothing;

  select count(*) into v_despues from public.notificaciones;
  return v_despues - v_antes;
end $$;

-- -----------------------------------------------------------------------------
-- Auditoría de las tablas nuevas
-- -----------------------------------------------------------------------------
create trigger servicios_auditoria after insert or update or delete on public.servicios for each row execute function public.auditar();
create trigger presupuestos_auditoria after insert or update or delete on public.presupuestos for each row execute function public.auditar();
create trigger presupuesto_items_auditoria after insert or update or delete on public.presupuesto_items for each row execute function public.auditar();
create trigger entrevistas_auditoria after insert or update or delete on public.entrevistas for each row execute function public.auditar();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.servicios         enable row level security;
alter table public.presupuestos      enable row level security;
alter table public.presupuesto_items enable row level security;
alter table public.entrevistas       enable row level security;
alter table public.notificaciones    enable row level security;
alter table public.dispositivos      enable row level security;

create policy servicios_lectura on public.servicios for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'presupuestos.ver')) or (select public.tiene_permiso(organizacion_id, 'catalogo.gestionar')));
create policy servicios_alta on public.servicios for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'catalogo.gestionar')));
create policy servicios_edicion on public.servicios for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'catalogo.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'catalogo.gestionar')));
create policy servicios_baja on public.servicios for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'catalogo.gestionar')));

do $$
declare t text;
begin
  foreach t in array array['presupuestos','presupuesto_items'] loop
    execute format('create policy %1$s_lectura on public.%1$s for select to authenticated
                      using ((select public.tiene_permiso(organizacion_id, ''presupuestos.ver'')))', t);
    execute format('create policy %1$s_alta on public.%1$s for insert to authenticated
                      with check ((select public.tiene_permiso(organizacion_id, ''presupuestos.gestionar'')))', t);
    execute format('create policy %1$s_edicion on public.%1$s for update to authenticated
                      using ((select public.tiene_permiso(organizacion_id, ''presupuestos.gestionar'')))
                      with check ((select public.tiene_permiso(organizacion_id, ''presupuestos.gestionar'')))', t);
    execute format('create policy %1$s_baja on public.%1$s for delete to authenticated
                      using ((select public.tiene_permiso(organizacion_id, ''presupuestos.gestionar'')))', t);
  end loop;
end $$;

create policy entrevistas_lectura on public.entrevistas for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'entrevistas.ver')) or asignada_a = (select auth.uid()));
create policy entrevistas_alta on public.entrevistas for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'entrevistas.gestionar')));
create policy entrevistas_edicion on public.entrevistas for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'entrevistas.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'entrevistas.gestionar')));
create policy entrevistas_baja on public.entrevistas for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'entrevistas.gestionar')));

create policy notificaciones_propias on public.notificaciones for select to authenticated
  using (usuario_id = (select auth.uid()));
create policy notificaciones_marcar on public.notificaciones for update to authenticated
  using (usuario_id = (select auth.uid())) with check (usuario_id = (select auth.uid()));
create policy dispositivos_propios on public.dispositivos for select to authenticated
  using (usuario_id = (select auth.uid()));

-- Solo se puede marcar como leída una notificación (nada más).
create or replace function public.proteger_notificacion()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and
     (new.titulo, new.cuerpo, new.url, new.usuario_id, new.organizacion_id, new.tipo, new.clave, new.push_enviada_at)
     is distinct from (old.titulo, old.cuerpo, old.url, old.usuario_id, old.organizacion_id, old.tipo, old.clave, old.push_enviada_at) then
    raise exception 'Solo podés marcar la notificación como leída.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger notificaciones_proteger before update on public.notificaciones
  for each row execute function public.proteger_notificacion();

-- Privilegios
grant select, insert, update, delete on public.servicios, public.presupuestos, public.presupuesto_items, public.entrevistas to authenticated;
grant select, update on public.notificaciones to authenticated;
grant select on public.dispositivos to authenticated;
grant execute on function public.aceptar_presupuesto(uuid, text), public.registrar_dispositivo(text, text), public.quitar_dispositivo(text) to authenticated;
revoke execute on function public.vencer_presupuestos(), public.generar_recordatorios(),
  public.notificar(uuid, uuid[], text, text, text, text, text), public.usuarios_con_permiso(uuid, text) from public, anon, authenticated;
-- pagos_numerar y otras funciones de trigger no necesitan EXECUTE explícito.

-- Tareas programadas
do $$
begin
  perform cron.schedule('festy_vencer_presupuestos', '20 3 * * *', 'select public.vencer_presupuestos()');
  -- 12:00 UTC = 09:00 en Argentina
  perform cron.schedule('festy_recordatorios', '0 12 * * *', 'select public.generar_recordatorios()');
exception when others then
  raise warning 'pg_cron no disponible (%): programar vencer_presupuestos y generar_recordatorios externamente.', sqlerrm;
end $$;
