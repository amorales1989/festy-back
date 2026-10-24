-- =============================================================================
-- Festy · Migración 23: suspensión de empresas (por falta de pago).
--
-- El bloqueo ya está en la base: es_miembro() y tiene_permiso() excluyen las
-- organizaciones con estado 'suspendida', así que sus usuarios no ven ni tocan
-- nada (RLS y SP) y su página pública deja de verse. Acá se agrega:
--   * quién y cómo se suspende/reactiva (solo la administración, vía service_role);
--   * motivo y fecha de la suspensión;
--   * un SP para que el usuario sepa que su empresa está suspendida (en vez de
--     "no tener empresa") y lo vea con claridad.
-- =============================================================================

alter table public.organizaciones
  add column suspendida_at timestamptz,
  add column suspension_motivo text check (suspension_motivo is null or length(suspension_motivo) <= 300);

-- Los datos de la suspensión los fija la administración, no la empresa.
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
    or new.suscripcion_precio is distinct from old.suscripcion_precio
    or new.suspendida_at is distinct from old.suspendida_at
    or new.suspension_motivo is distinct from old.suspension_motivo) then
    raise exception 'Estos datos de la cuenta no se pueden modificar desde acá.' using errcode = '42501';
  end if;
  return new;
end $$;

-- Empresas suspendidas a las que pertenece el usuario (para mostrarle el aviso).
create or replace function api.sp_mis_empresas_suspendidas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre, 'motivo', o.suspension_motivo, 'suspendida_at', o.suspendida_at)
                             order by o.nombre))
    from public.organizaciones o join public.membresias m on m.organizacion_id = o.id
   where m.usuario_id = auth.uid() and m.activo and o.estado = 'suspendida'
$$;

-- Suspender o reactivar (solo la API de administración).
create or replace function api.sp_plataforma_estado(p_org uuid, p_estado text, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_actual public.estado_organizacion;
begin
  select estado into v_actual from public.organizaciones where id = p_org for update;
  if not found then raise exception 'La empresa no existe.' using errcode = 'P0002'; end if;
  if p_estado not in ('activa', 'suspendida') then raise exception 'Estado no válido.' using errcode = '22023'; end if;
  if v_actual = 'baja_solicitada' then
    raise exception 'La empresa pidió la baja: no se puede suspender ni reactivar desde acá.' using errcode = '23514';
  end if;
  update public.organizaciones
     set estado = p_estado::public.estado_organizacion,
         suspendida_at = case when p_estado = 'suspendida' then coalesce(case when v_actual = 'suspendida' then suspendida_at end, now()) end,
         suspension_motivo = case when p_estado = 'suspendida' then nullif(trim(coalesce(p_motivo, '')), '') end
   where id = p_org;
end $$;

-- El listado de la administración suma motivo y fecha de suspensión.
create or replace function api.sp_plataforma_empresas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object(
           'id', o.id, 'nombre', o.nombre, 'estado', o.estado, 'creado_at', o.creado_at,
           'suspendida_at', o.suspendida_at, 'suspension_motivo', o.suspension_motivo,
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

revoke execute on function api.sp_mis_empresas_suspendidas() from public, anon;
grant execute on function api.sp_mis_empresas_suspendidas() to authenticated;
revoke execute on function api.sp_plataforma_estado(uuid, text, text), api.sp_plataforma_empresas() from public, anon, authenticated;
grant execute on function api.sp_plataforma_estado(uuid, text, text), api.sp_plataforma_empresas() to service_role;
