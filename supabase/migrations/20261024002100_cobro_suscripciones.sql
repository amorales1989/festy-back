-- =============================================================================
-- Festy · Migración 21: cobro de la suscripción de cada empresa (fuera de la app).
--
-- El administrador de la plataforma registra lo que paga cada empresa: precio
-- mensual (tarifa por cantidad de sedes, o un precio especial) y pagos (fecha, monto, medio, cuántos meses cubre). Cada pago
-- extiende la cobertura desde donde terminaba la anterior (o desde la fecha de
-- pago si estaba vencida). "Pagado hasta" = fin de la última cobertura.
-- Solo la API, con service_role, usa estos SP (después de verificar que quien
-- llama es administrador de la plataforma). Las empresas no ven estos pagos.
-- =============================================================================

alter table public.organizaciones add column suscripcion_precio numeric(14,2) check (suscripcion_precio is null or suscripcion_precio >= 0);

create table public.suscripcion_pagos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  fecha           date not null,
  monto           numeric(14,2) not null check (monto > 0),
  medio           text not null default 'transferencia'
                    check (medio in ('efectivo','transferencia','mercadopago','tarjeta_debito','tarjeta_credito','cheque','otro')),
  meses           int not null default 1 check (meses between 1 and 36),
  cubre_desde     date not null,
  cubre_hasta     date not null,
  notas           text,
  registrado_por  text,
  creado_at       timestamptz not null default now(),
  check (cubre_hasta > cubre_desde)
);
create index suscripcion_pagos_org_idx on public.suscripcion_pagos (organizacion_id, cubre_hasta desc);
-- Sin políticas: con RLS activa, ningún usuario de las empresas puede leerlos ni tocarlos.
alter table public.suscripcion_pagos enable row level security;

-- El precio lo fija la administración, no la empresa.
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
    or new.ultimo_numero_garantia is distinct from old.ultimo_numero_garantia
    or new.suscripcion_precio is distinct from old.suscripcion_precio) then
    raise exception 'Estos datos de la cuenta no se pueden modificar desde acá.' using errcode = '42501';
  end if;
  return new;
end $$;

-- Tarifa de Festy: $30.000 por mes con una sede y $15.000 por cada sede (salón físico) extra.
-- Es el precio por defecto; la administración puede fijar un precio especial por empresa.
create or replace function public.tarifa_festy(p_sedes int)
returns numeric language sql immutable set search_path = '' as $$
  select 30000 + 15000 * greatest(coalesce(p_sedes, 0) - 1, 0)::numeric
$$;

-- Listado de empresas: suma precio, último pago y hasta cuándo está pagada.
create or replace function api.sp_plataforma_empresas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object(
           'id', o.id, 'nombre', o.nombre, 'estado', o.estado, 'creado_at', o.creado_at,
           'duenio', (select jsonb_build_object('nombre', p.nombre, 'email', u.email, 'ultimo_ingreso', u.last_sign_in_at)
                        from public.membresias m join public.roles r on r.id = m.rol_id and r.clave = 'propietario'
                        join auth.users u on u.id = m.usuario_id left join public.perfiles p on p.id = u.id
                       where m.organizacion_id = o.id order by m.creado_at limit 1),
           'usuarios', (select count(*) from public.membresias m where m.organizacion_id = o.id and m.activo),
           'eventos', (select count(*) from public.reservas r where r.organizacion_id = o.id and not r.es_ejemplo),
           'ultimo_evento_cargado', (select max(r.creado_at) from public.reservas r where r.organizacion_id = o.id and not r.es_ejemplo),
           'pagina', case when o.pagina_activa then o.pagina_slug end,
           'sedes', (select count(*) from public.sucursales su where su.organizacion_id = o.id and su.activo and not su.es_ejemplo),
           'precio_tarifa', public.tarifa_festy((select count(*)::int from public.sucursales su where su.organizacion_id = o.id and su.activo and not su.es_ejemplo)),
           'precio_especial', o.suscripcion_precio,
           'precio', coalesce(o.suscripcion_precio,
                              public.tarifa_festy((select count(*)::int from public.sucursales su where su.organizacion_id = o.id and su.activo and not su.es_ejemplo))),
           'pagado_hasta', (select max(sp.cubre_hasta) from public.suscripcion_pagos sp where sp.organizacion_id = o.id),
           'ultimo_pago', (select jsonb_build_object('id', sp.id, 'fecha', sp.fecha, 'monto', sp.monto, 'medio', sp.medio, 'meses', sp.meses)
                             from public.suscripcion_pagos sp where sp.organizacion_id = o.id order by sp.fecha desc, sp.creado_at desc limit 1))
           order by o.creado_at desc))
    from public.organizaciones o
$$;

create or replace function api.sp_plataforma_precio(p_org uuid, p_precio numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.organizaciones set suscripcion_precio = p_precio where id = p_org;
  if not found then raise exception 'La empresa no existe.' using errcode = 'P0002'; end if;
end $$;

create or replace function api.sp_plataforma_pagos(p_org uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(sp) order by sp.fecha desc, sp.creado_at desc))
    from public.suscripcion_pagos sp where sp.organizacion_id = p_org
$$;

-- Registra un pago: cubre `meses` desde el fin de la cobertura vigente (o desde la fecha si estaba vencida).
create or replace function api.sp_plataforma_pago_registrar(p_org uuid, p_datos jsonb, p_registrado_por text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_fecha date := (p_datos->>'fecha')::date;
  v_meses int := coalesce(nullif(p_datos->>'meses', '')::int, 1);
  v_hasta_actual date;
  v_desde date;
  v jsonb;
begin
  if not exists (select 1 from public.organizaciones where id = p_org) then
    raise exception 'La empresa no existe.' using errcode = 'P0002';
  end if;
  if v_fecha is null then raise exception 'Indicá la fecha del pago.' using errcode = '23514'; end if;
  perform 1 from public.organizaciones where id = p_org for update;  -- dos pagos a la vez no se pisan la cobertura
  select max(cubre_hasta) into v_hasta_actual from public.suscripcion_pagos where organizacion_id = p_org;
  v_desde := case when v_hasta_actual is not null and v_hasta_actual >= v_fecha then v_hasta_actual else v_fecha end;
  insert into public.suscripcion_pagos (organizacion_id, fecha, monto, medio, meses, cubre_desde, cubre_hasta, notas, registrado_por)
  values (p_org, v_fecha, (p_datos->>'monto')::numeric, coalesce(nullif(p_datos->>'medio', ''), 'transferencia'), v_meses,
          v_desde, (v_desde + make_interval(months => v_meses))::date, nullif(trim(coalesce(p_datos->>'notas', '')), ''), p_registrado_por)
  returning to_jsonb(suscripcion_pagos.*) into v;
  return v;
end $$;

create or replace function api.sp_plataforma_pago_eliminar(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.suscripcion_pagos where id = p_id;
  if not found then raise exception 'El pago no existe.' using errcode = 'P0002'; end if;
end $$;

revoke execute on function api.sp_plataforma_empresas(), api.sp_plataforma_precio(uuid, numeric), api.sp_plataforma_pagos(uuid),
  api.sp_plataforma_pago_registrar(uuid, jsonb, text), api.sp_plataforma_pago_eliminar(uuid) from public, anon, authenticated;
grant execute on function api.sp_plataforma_empresas(), api.sp_plataforma_precio(uuid, numeric), api.sp_plataforma_pagos(uuid),
  api.sp_plataforma_pago_registrar(uuid, jsonb, text), api.sp_plataforma_pago_eliminar(uuid) to service_role;
