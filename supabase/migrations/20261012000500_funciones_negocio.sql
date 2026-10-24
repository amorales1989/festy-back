-- =============================================================================
-- Festy · Migración 5: funciones de negocio (RPC), permisos de ejecución y
-- tareas programadas.
--
-- Convención: las RPC SECURITY INVOKER respetan la RLS del usuario. Las
-- SECURITY DEFINER validan explícitamente el permiso con exigir_permiso().
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Alta de organización (onboarding)
-- -----------------------------------------------------------------------------
create or replace function public.crear_organizacion(p_nombre text, p_zona_horaria text default 'America/Argentina/Buenos_Aires')
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_rol_prop uuid;
  v_cant int;
begin
  if v_uid is null then
    raise exception 'Necesitás iniciar sesión.' using errcode = '28000';
  end if;
  select count(*) into v_cant from public.organizaciones where creado_por = v_uid and creado_at > now() - interval '1 day';
  if v_cant >= 5 then
    raise exception 'Alcanzaste el máximo de organizaciones creadas por día.' using errcode = 'P0001';
  end if;

  insert into public.organizaciones (nombre, zona_horaria, creado_por, email_contacto)
  values (trim(p_nombre), coalesce(nullif(p_zona_horaria, ''), 'America/Argentina/Buenos_Aires'), v_uid,
          (select email from auth.users where id = v_uid))
  returning id into v_org;

  insert into public.roles (organizacion_id, clave, nombre, descripcion, es_sistema)
  select v_org, clave, nombre, descripcion, true from public.roles_plantilla order by orden;

  insert into public.rol_permisos (organizacion_id, rol_id, permiso)
  select v_org, r.id, unnest(rp.permisos)
  from public.roles r join public.roles_plantilla rp on rp.clave = r.clave
  where r.organizacion_id = v_org;

  select id into v_rol_prop from public.roles where organizacion_id = v_org and clave = 'propietario';
  insert into public.membresias (organizacion_id, usuario_id, rol_id) values (v_org, v_uid, v_rol_prop);
  update public.perfiles set organizacion_actual = v_org where id = v_uid;
  return v_org;
end $$;

-- -----------------------------------------------------------------------------
-- Invitaciones
-- -----------------------------------------------------------------------------
create or replace function public.ver_invitacion(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v record;
begin
  select i.*, o.nombre as organizacion, r.nombre as rol
    into v
    from public.invitaciones i
    join public.organizaciones o on o.id = i.organizacion_id
    join public.roles r on r.id = i.rol_id
   where i.token = p_token;
  if not found then
    return jsonb_build_object('valida', false, 'motivo', 'La invitación no existe.');
  end if;
  return jsonb_build_object(
    'valida', v.aceptada_at is null and not v.revocada and v.expira_at > now(),
    'motivo', case when v.aceptada_at is not null then 'La invitación ya fue aceptada.'
                   when v.revocada then 'La invitación fue revocada.'
                   when v.expira_at <= now() then 'La invitación venció. Pedí una nueva.' end,
    'organizacion', v.organizacion, 'rol', v.rol, 'email', v.email);
end $$;

create or replace function public.aceptar_invitacion(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_inv public.invitaciones;
  v_email text;
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Necesitás iniciar sesión para aceptar la invitación.' using errcode = '28000';
  end if;
  select * into v_inv from public.invitaciones where token = p_token for update;
  if not found or v_inv.revocada then
    raise exception 'La invitación no es válida.' using errcode = 'P0001';
  end if;
  if v_inv.aceptada_at is not null then
    raise exception 'La invitación ya fue aceptada.' using errcode = 'P0001';
  end if;
  if v_inv.expira_at <= now() then
    raise exception 'La invitación venció. Pedí una nueva.' using errcode = 'P0001';
  end if;
  select email into v_email from auth.users where id = v_uid;
  if lower(v_email) <> lower(v_inv.email) then
    raise exception 'Esta invitación fue enviada a %. Ingresá con esa cuenta.', v_inv.email using errcode = '42501';
  end if;

  insert into public.membresias (organizacion_id, usuario_id, rol_id)
  values (v_inv.organizacion_id, v_uid, v_inv.rol_id)
  on conflict (organizacion_id, usuario_id) do update set rol_id = excluded.rol_id, activo = true;

  update public.invitaciones set aceptada_at = now(), aceptada_por = v_uid where id = v_inv.id;
  update public.perfiles set organizacion_actual = v_inv.organizacion_id where id = v_uid;
  return v_inv.organizacion_id;
end $$;

create or replace function public.listar_miembros(p_org uuid)
returns table (membresia_id uuid, usuario_id uuid, nombre text, email text, rol_id uuid, rol text, rol_clave text, activo boolean, creado_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select m.id, m.usuario_id, p.nombre, p.email, r.id, r.nombre, r.clave, m.activo, m.creado_at
  from public.membresias m
  join public.perfiles p on p.id = m.usuario_id
  join public.roles r on r.id = m.rol_id
  where m.organizacion_id = p_org
  order by m.activo desc, p.nombre
$$;

-- -----------------------------------------------------------------------------
-- Reservas: guardado atómico (datos + espacios)
-- -----------------------------------------------------------------------------
create or replace function public.guardar_reserva(p_org uuid, p_id uuid, p_datos jsonb, p_espacios jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := p_id;
  v_estado public.estado_reserva := coalesce((p_datos->>'estado')::public.estado_reserva, 'consulta');
  v_espacios uuid[];
begin
  select coalesce(array_agg((e->>'espacio_id')::uuid), '{}') into v_espacios
    from jsonb_array_elements(coalesce(p_espacios, '[]'::jsonb)) e;

  if cardinality(v_espacios) = 0 and v_estado not in ('consulta', 'cancelada') then
    raise exception 'Elegí al menos un espacio para la reserva.' using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.reservas (organizacion_id, sucursal_id, cliente_id, titulo, tipo_evento, estado, inicio, fin,
                                 invitados, responsable_id, contrato_estado, precio_total, notas, vence_tentativa_at)
    values (p_org,
            (p_datos->>'sucursal_id')::uuid,
            (p_datos->>'cliente_id')::uuid,
            p_datos->>'titulo',
            coalesce(p_datos->>'tipo_evento', 'otro'),
            v_estado,
            (p_datos->>'inicio')::timestamptz,
            (p_datos->>'fin')::timestamptz,
            nullif(p_datos->>'invitados', '')::int,
            nullif(p_datos->>'responsable_id', '')::uuid,
            coalesce((p_datos->>'contrato_estado')::public.estado_contrato, 'pendiente'),
            coalesce(nullif(p_datos->>'precio_total', '')::numeric, 0),
            p_datos->>'notas',
            nullif(p_datos->>'vence_tentativa_at', '')::timestamptz)
    returning id into v_id;
  else
    -- primero se quitan los espacios descartados (libera la agenda y permite cambiar de sucursal)
    delete from public.reserva_espacios
     where reserva_id = v_id and organizacion_id = p_org and not (espacio_id = any (v_espacios));

    update public.reservas r set
      sucursal_id     = case when p_datos ? 'sucursal_id' then (p_datos->>'sucursal_id')::uuid else r.sucursal_id end,
      cliente_id      = case when p_datos ? 'cliente_id' then (p_datos->>'cliente_id')::uuid else r.cliente_id end,
      titulo          = case when p_datos ? 'titulo' then p_datos->>'titulo' else r.titulo end,
      tipo_evento     = case when p_datos ? 'tipo_evento' then p_datos->>'tipo_evento' else r.tipo_evento end,
      estado          = case when p_datos ? 'estado' then v_estado else r.estado end,
      inicio          = case when p_datos ? 'inicio' then (p_datos->>'inicio')::timestamptz else r.inicio end,
      fin             = case when p_datos ? 'fin' then (p_datos->>'fin')::timestamptz else r.fin end,
      invitados       = case when p_datos ? 'invitados' then nullif(p_datos->>'invitados', '')::int else r.invitados end,
      responsable_id  = case when p_datos ? 'responsable_id' then nullif(p_datos->>'responsable_id', '')::uuid else r.responsable_id end,
      contrato_estado = case when p_datos ? 'contrato_estado' then (p_datos->>'contrato_estado')::public.estado_contrato else r.contrato_estado end,
      precio_total    = case when p_datos ? 'precio_total' then coalesce(nullif(p_datos->>'precio_total', '')::numeric, 0) else r.precio_total end,
      notas           = case when p_datos ? 'notas' then p_datos->>'notas' else r.notas end,
      motivo_cancelacion = case when p_datos ? 'motivo_cancelacion' then p_datos->>'motivo_cancelacion' else r.motivo_cancelacion end,
      vence_tentativa_at = case when p_datos ? 'vence_tentativa_at' then nullif(p_datos->>'vence_tentativa_at', '')::timestamptz else r.vence_tentativa_at end
    where r.id = v_id and r.organizacion_id = p_org;
    if not found then
      raise exception 'La reserva no existe o no tenés permiso para editarla.' using errcode = '42501';
    end if;
  end if;

  insert into public.reserva_espacios (organizacion_id, reserva_id, espacio_id, antes_min, despues_min)
  select p_org, v_id, (e->>'espacio_id')::uuid, nullif(e->>'antes_min', '')::int, nullif(e->>'despues_min', '')::int
    from jsonb_array_elements(coalesce(p_espacios, '[]'::jsonb)) e
  on conflict (reserva_id, espacio_id) do update
    set antes_min = coalesce(excluded.antes_min, public.reserva_espacios.antes_min),
        despues_min = coalesce(excluded.despues_min, public.reserva_espacios.despues_min)
    where excluded.antes_min is not null or excluded.despues_min is not null;

  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- Cobros: registra el pago y, si es seña, pasa la reserva a "señada".
-- -----------------------------------------------------------------------------
create or replace function public.registrar_pago(
  p_reserva uuid, p_monto numeric, p_fecha date, p_medio text, p_concepto text,
  p_referencia text default null, p_notas text default null)
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

  insert into public.pagos (organizacion_id, reserva_id, fecha, monto, medio, concepto, referencia, notas, registrado_por)
  values (v_r.organizacion_id, p_reserva, p_fecha, p_monto, p_medio, p_concepto, nullif(p_referencia, ''), nullif(p_notas, ''), auth.uid())
  returning id into v_id;

  if p_concepto = 'sena' and v_r.estado in ('consulta', 'tentativa') then
    if not exists (select 1 from public.reserva_espacios where reserva_id = p_reserva) then
      raise exception 'Asigná un espacio a la reserva antes de registrar la seña.' using errcode = '23514';
    end if;
    update public.reservas set estado = 'senada' where id = p_reserva;
  end if;
  return v_id;
end $$;

-- -----------------------------------------------------------------------------
-- Disponibilidad: conflictos (bloqueantes) y avisos (feriados, horario, capacidad)
-- -----------------------------------------------------------------------------
create or replace function public.verificar_disponibilidad(
  p_org uuid, p_espacios uuid[], p_inicio timestamptz, p_fin timestamptz,
  p_excluir_reserva uuid default null, p_invitados int default null)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_tz text;
  v_conflictos jsonb := '[]'::jsonb;
  v_avisos jsonb := '[]'::jsonb;
  v_esp record;
  v_rango tstzrange;
  v_ini_local timestamp;
  v_fin_local timestamp;
  v_cap int := 0;
  v_ok boolean;
  v_fer record;
begin
  select zona_horaria into v_tz from public.organizaciones where id = p_org;
  if v_tz is null then
    raise exception 'Organización inexistente.' using errcode = 'P0002';
  end if;
  if p_fin <= p_inicio then
    return jsonb_build_object('conflictos', '[]'::jsonb,
      'avisos', jsonb_build_array('La hora de fin debe ser posterior a la de inicio.'), 'disponible', false);
  end if;
  v_ini_local := p_inicio at time zone v_tz;
  v_fin_local := p_fin at time zone v_tz;

  for v_esp in
    select e.*, re.antes_min as r_antes, re.despues_min as r_despues
      from public.espacios e
      left join public.reserva_espacios re on re.espacio_id = e.id and re.reserva_id = p_excluir_reserva
     where e.organizacion_id = p_org and e.id = any (p_espacios)
  loop
    v_cap := v_cap + v_esp.capacidad_maxima;
    v_rango := tstzrange(
      p_inicio - make_interval(mins => coalesce(v_esp.r_antes, v_esp.preparacion_min + v_esp.montaje_min)),
      p_fin + make_interval(mins => coalesce(v_esp.r_despues, v_esp.desmontaje_min + v_esp.limpieza_min)), '[)');

    v_conflictos := v_conflictos || coalesce((
      select jsonb_agg(jsonb_build_object(
        'espacio_id', v_esp.id, 'espacio', v_esp.nombre,
        'desde', lower(o.rango), 'hasta', upper(o.rango),
        'reserva_id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'estado', r.estado,
        'bloqueo', b.id is not null, 'motivo', coalesce(b.motivo, b.tipo)))
      from public.ocupaciones o
      left join public.reserva_espacios re on re.id = o.reserva_espacio_id
      left join public.reservas r on r.id = re.reserva_id
      left join public.bloqueos b on b.id = o.bloqueo_id
      where o.espacio_id = v_esp.id and o.bloqueante and o.rango && v_rango
        and (p_excluir_reserva is null or re.reserva_id is distinct from p_excluir_reserva)), '[]'::jsonb);

    -- Consultas abiertas sobre el mismo espacio y horario (no bloquean, pero conviene saberlo)
    if exists (
      select 1 from public.ocupaciones o
        join public.reserva_espacios re on re.id = o.reserva_espacio_id
       where o.espacio_id = v_esp.id and not o.bloqueante and o.rango && v_rango
         and re.reserva_id is distinct from p_excluir_reserva
         and exists (select 1 from public.reservas r where r.id = re.reserva_id and r.estado = 'consulta')) then
      v_avisos := v_avisos || to_jsonb(format('Hay otras consultas abiertas para "%s" en ese horario.', v_esp.nombre));
    end if;

    -- Horario de atención (solo si el espacio tiene horarios cargados)
    if exists (select 1 from public.espacio_horarios where espacio_id = v_esp.id) then
      select exists (
        select 1 from public.espacio_horarios h,
             lateral (select d::date as dia from generate_series(v_ini_local::date - 1, v_ini_local::date, interval '1 day') d) dd
         where h.espacio_id = v_esp.id
           and h.dia_semana = extract(dow from dd.dia)
           and v_ini_local >= dd.dia + h.hora_desde
           and v_fin_local <= dd.dia + h.hora_hasta + case when h.hora_hasta <= h.hora_desde then interval '1 day' else interval '0' end
      ) into v_ok;
      if not v_ok then
        v_avisos := v_avisos || to_jsonb(format('El horario está fuera de la atención configurada para "%s".', v_esp.nombre));
      end if;
    end if;
    if p_fin - p_inicio < make_interval(mins => v_esp.duracion_minima_min) then
      v_avisos := v_avisos || to_jsonb(format('La duración mínima para "%s" es de %s minutos.', v_esp.nombre, v_esp.duracion_minima_min));
    end if;
  end loop;

  for v_fer in
    select fecha, nombre from public.feriados
     where (organizacion_id is null or organizacion_id = p_org)
       and fecha between v_ini_local::date and v_fin_local::date
     order by fecha
  loop
    v_avisos := v_avisos || to_jsonb(format('%s es feriado: %s.', to_char(v_fer.fecha, 'DD/MM/YYYY'), v_fer.nombre));
  end loop;

  if p_invitados is not null and v_cap > 0 and p_invitados > v_cap then
    v_avisos := v_avisos || to_jsonb(format('La capacidad de los espacios elegidos es de %s personas.', v_cap));
  end if;

  return jsonb_build_object('conflictos', v_conflictos, 'avisos', v_avisos,
                            'disponible', jsonb_array_length(v_conflictos) = 0);
end $$;

-- -----------------------------------------------------------------------------
-- Panel principal: todos los indicadores salen de datos reales y respetan la
-- RLS. Los bloques financieros devuelven null si el usuario no tiene permiso.
-- -----------------------------------------------------------------------------
create or replace function public.panel_resumen(
  p_org uuid, p_desde date, p_hasta date,
  p_salon uuid default null, p_sucursal uuid default null, p_responsable uuid default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_tz text;
  v_hoy date;
  v_ahora timestamptz := now();
  v_ini timestamptz;
  v_fin timestamptz;
  v_pagos boolean := public.tiene_permiso(p_org, 'pagos.ver');
  v_gastos boolean := public.tiene_permiso(p_org, 'gastos.ver');
  v_sucursales uuid[];
  v_res jsonb := '{}'::jsonb;
  v_espacios_total int;
  v_ocupados int;
  v_dias int;
begin
  if not public.es_miembro(p_org) then
    raise exception 'No tenés acceso a esta organización.' using errcode = '42501';
  end if;
  if p_hasta < p_desde or p_hasta - p_desde > 366 then
    raise exception 'El período elegido no es válido (máximo un año).' using errcode = '22023';
  end if;
  select zona_horaria into v_tz from public.organizaciones where id = p_org;
  v_hoy := (v_ahora at time zone v_tz)::date;
  v_ini := p_desde::timestamp at time zone v_tz;
  v_fin := (p_hasta + 1)::timestamp at time zone v_tz;

  select array_agg(s.id) into v_sucursales
    from public.sucursales s
   where s.organizacion_id = p_org
     and (p_salon is null or s.salon_id = p_salon)
     and (p_sucursal is null or s.id = p_sucursal);
  v_sucursales := coalesce(v_sucursales, '{}');

  create temp table if not exists _panel_reservas (like public.reservas) on commit drop;
  truncate _panel_reservas;
  insert into _panel_reservas
  select r.* from public.reservas r
   where r.organizacion_id = p_org and r.sucursal_id = any (v_sucursales)
     and (p_responsable is null or r.responsable_id = p_responsable);

  -- Eventos de hoy
  v_res := v_res || jsonb_build_object('eventos_hoy', coalesce((
    select jsonb_agg(x order by x->>'inicio') from (
      select jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'estado', r.estado,
                                'inicio', r.inicio, 'fin', r.fin, 'invitados', r.invitados,
                                'espacios', (select string_agg(e.nombre, ', ' order by e.nombre)
                                               from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id
                                              where re.reserva_id = r.id)) x
      from _panel_reservas r
      where r.estado in ('tentativa','senada','confirmada','finalizada')
        and r.inicio < ((v_hoy + 1)::timestamp at time zone v_tz) and r.fin > (v_hoy::timestamp at time zone v_tz)
    ) t), '[]'::jsonb));

  -- Próximas reservas (siguientes 10)
  v_res := v_res || jsonb_build_object('proximas', coalesce((
    select jsonb_agg(x) from (
      select jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'estado', r.estado,
                                'inicio', r.inicio, 'fin', r.fin, 'invitados', r.invitados,
                                'cliente', c.nombre) x
      from _panel_reservas r left join public.clientes c on c.id = r.cliente_id
      where r.estado in ('tentativa','senada','confirmada') and r.inicio >= v_ahora
      order by r.inicio limit 10) t), '[]'::jsonb));

  -- Consultas nuevas (últimos 7 días) y todas las abiertas
  v_res := v_res || jsonb_build_object(
    'consultas_nuevas', (select count(*) from _panel_reservas where estado = 'consulta' and creado_at >= v_ahora - interval '7 days'),
    'consultas_abiertas', (select count(*) from _panel_reservas where estado = 'consulta' and fin >= v_ahora),
    'consultas', coalesce((select jsonb_agg(x) from (
       select jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'inicio', r.inicio, 'creado_at', r.creado_at) x
       from _panel_reservas r where r.estado = 'consulta' and r.fin >= v_ahora order by r.creado_at desc limit 5) t), '[]'::jsonb));

  -- Tentativas (con vencimiento)
  v_res := v_res || jsonb_build_object(
    'tentativas', (select count(*) from _panel_reservas where estado = 'tentativa'),
    'tentativas_por_vencer', coalesce((select jsonb_agg(x) from (
       select jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'inicio', r.inicio, 'vence', r.vence_tentativa_at) x
       from _panel_reservas r where r.estado = 'tentativa' order by r.vence_tentativa_at nulls last limit 5) t), '[]'::jsonb));

  -- Contratos pendientes de firma en reservas vigentes
  v_res := v_res || jsonb_build_object(
    'contratos_pendientes', (select count(*) from _panel_reservas
                              where estado in ('senada','confirmada') and contrato_estado in ('pendiente','enviado') and fin >= v_ahora));

  -- Cobros y deuda
  if v_pagos then
    v_res := v_res || jsonb_build_object(
      'cobros_proximos', coalesce((select jsonb_agg(x) from (
         select jsonb_build_object('cuota_id', ce.id, 'reserva_id', r.id, 'numero', r.numero, 'titulo', r.titulo,
                                   'vencimiento', ce.vencimiento, 'pendiente', ce.pendiente) x
         from public.v_cuotas_estado ce join _panel_reservas r on r.id = ce.reserva_id
         where ce.pendiente > 0 and ce.vencimiento between v_hoy and v_hoy + 14 and r.estado <> 'cancelada'
         order by ce.vencimiento limit 10) t), '[]'::jsonb),
      'cobros_proximos_total', (select coalesce(sum(ce.pendiente), 0)
         from public.v_cuotas_estado ce join _panel_reservas r on r.id = ce.reserva_id
         where ce.pendiente > 0 and ce.vencimiento between v_hoy and v_hoy + 14 and r.estado <> 'cancelada'),
      'deuda_vencida', (select coalesce(sum(s.vencido), 0) from public.v_reservas_saldo s
         join _panel_reservas r on r.id = s.reserva_id where r.estado <> 'cancelada'),
      'deuda_vencida_reservas', (select count(*) from public.v_reservas_saldo s
         join _panel_reservas r on r.id = s.reserva_id where r.estado <> 'cancelada' and s.vencido > 0),
      'ingresos', (select coalesce(sum(p.monto), 0) from public.pagos p join _panel_reservas r on r.id = p.reserva_id
         where not p.anulado and p.fecha between p_desde and p_hasta));
  else
    v_res := v_res || jsonb_build_object('cobros_proximos', null, 'cobros_proximos_total', null,
                                         'deuda_vencida', null, 'deuda_vencida_reservas', null, 'ingresos', null);
  end if;

  if v_gastos then
    v_res := v_res || jsonb_build_object('gastos', (
      select coalesce(sum(g.monto), 0) from public.gastos g
       where g.organizacion_id = p_org and g.fecha between p_desde and p_hasta
         and (p_sucursal is null and p_salon is null or g.sucursal_id = any (v_sucursales))));
  else
    v_res := v_res || jsonb_build_object('gastos', null);
  end if;

  -- Ocupación: días-espacio con al menos una reserva bloqueante / días-espacio totales del período
  v_dias := p_hasta - p_desde + 1;
  select count(*) into v_espacios_total from public.espacios e
   where e.organizacion_id = p_org and e.activo and e.sucursal_id = any (v_sucursales);
  select count(*) into v_ocupados from (
    select distinct e.id, d.dia
      from public.espacios e
      cross join lateral (select g::date as dia from generate_series(p_desde, p_hasta, interval '1 day') g) d
     where e.organizacion_id = p_org and e.activo and e.sucursal_id = any (v_sucursales)
       and exists (
         select 1 from public.reserva_espacios re join _panel_reservas r on r.id = re.reserva_id
          where re.espacio_id = e.id and public.estado_bloquea(r.estado)
            and public.ocupa_dia(tstzrange(r.inicio, r.fin, '[)'), d.dia, v_tz))
  ) t;
  v_res := v_res || jsonb_build_object(
    'ocupacion_pct', case when v_espacios_total * v_dias = 0 then 0
                          else round(100.0 * v_ocupados / (v_espacios_total * v_dias), 1) end,
    'espacios_activos', v_espacios_total,
    'reservas_periodo', (select count(*) from _panel_reservas r
                          where public.estado_bloquea(r.estado) and r.inicio < v_fin and r.fin > v_ini));

  -- Fechas disponibles: próximos 60 días con al menos un espacio sin ocupación bloqueante
  v_res := v_res || jsonb_build_object('fechas_disponibles', coalesce((
    select jsonb_agg(x order by x->>'fecha') from (
      select jsonb_build_object('fecha', d.dia, 'libres', count(e.id), 'total', v_espacios_total) x
        from (select g::date as dia from generate_series(v_hoy, v_hoy + 60, interval '1 day') g) d
        join public.espacios e on e.organizacion_id = p_org and e.activo and e.sucursal_id = any (v_sucursales)
       where not exists (
               select 1 from public.ocupaciones o
                where o.espacio_id = e.id and o.bloqueante
                  and public.ocupa_dia(o.rango, d.dia, v_tz))
         and extract(dow from d.dia) in (0, 5, 6)
       group by d.dia
       order by d.dia
       limit 8) t), '[]'::jsonb));

  -- Tareas pendientes
  if public.tiene_permiso(p_org, 'tareas.ver') then
    v_res := v_res || jsonb_build_object(
      'tareas_pendientes', (select count(*) from public.tareas t where t.organizacion_id = p_org and t.estado <> 'hecha'
                              and (p_responsable is null or t.asignada_a = p_responsable)),
      'tareas_vencidas', (select count(*) from public.tareas t where t.organizacion_id = p_org and t.estado <> 'hecha'
                              and t.vence_el < v_hoy and (p_responsable is null or t.asignada_a = p_responsable)),
      'tareas', coalesce((select jsonb_agg(x) from (
         select jsonb_build_object('id', t.id, 'titulo', t.titulo, 'vence_el', t.vence_el, 'prioridad', t.prioridad,
                                   'estado', t.estado, 'mia', t.asignada_a = auth.uid(), 'reserva_id', t.reserva_id) x
         from public.tareas t where t.organizacion_id = p_org and t.estado <> 'hecha'
           and (p_responsable is null or t.asignada_a = p_responsable)
         order by (t.asignada_a = auth.uid()) desc nulls last, t.vence_el nulls last, t.creado_at limit 8) s), '[]'::jsonb));
  else
    v_res := v_res || jsonb_build_object('tareas_pendientes', null, 'tareas_vencidas', null, 'tareas', '[]'::jsonb);
  end if;

  return v_res || jsonb_build_object('hoy', v_hoy, 'zona_horaria', v_tz,
                                     'permisos', jsonb_build_object('pagos', v_pagos, 'gastos', v_gastos));
end $$;

-- -----------------------------------------------------------------------------
-- Búsqueda global
-- -----------------------------------------------------------------------------
create or replace function public.buscar_global(p_org uuid, p_q text)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_q text := public.normalizar(trim(p_q));
  v_num int;
begin
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  v_num := case when v_q ~ '^#?\d{1,9}$' then ltrim(v_q, '#')::int end;
  return coalesce((
    select jsonb_agg(x) from (
      (select jsonb_build_object('tipo', 'cliente', 'id', c.id, 'titulo', c.nombre,
                                 'detalle', concat_ws(' · ', c.telefono, c.email)) x
         from public.clientes c
        where c.organizacion_id = p_org and c.busqueda like '%' || v_q || '%'
        order by c.nombre limit 6)
      union all
      (select jsonb_build_object('tipo', 'reserva', 'id', r.id, 'titulo', format('#%s %s', r.numero, r.titulo),
                                 'detalle', r.estado::text, 'inicio', r.inicio)
         from public.reservas r left join public.clientes c on c.id = r.cliente_id
        where r.organizacion_id = p_org
          and (r.numero = v_num or public.normalizar(r.titulo) like '%' || v_q || '%' or c.busqueda like '%' || v_q || '%')
        order by r.inicio desc limit 8)
    ) t), '[]'::jsonb);
end $$;

-- -----------------------------------------------------------------------------
-- Plan y baja de la cuenta
-- -----------------------------------------------------------------------------
create or replace function public.cambiar_plan(p_org uuid, p_plan text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_plan public.planes;
begin
  perform public.exigir_permiso(p_org, 'plan.gestionar');
  select * into v_plan from public.planes where clave = p_plan and activo;
  if not found then raise exception 'El plan no existe.' using errcode = 'P0002'; end if;
  if v_plan.max_sucursales is not null and (select count(*) from public.sucursales where organizacion_id = p_org and activo) > v_plan.max_sucursales then
    raise exception 'Tenés más sucursales activas que las que permite el plan %. Desactivá algunas primero.', v_plan.nombre using errcode = 'P0001';
  end if;
  if v_plan.max_espacios is not null and (select count(*) from public.espacios where organizacion_id = p_org and activo) > v_plan.max_espacios then
    raise exception 'Tenés más espacios activos que los que permite el plan %. Desactivá algunos primero.', v_plan.nombre using errcode = 'P0001';
  end if;
  if v_plan.max_usuarios is not null and (select count(*) from public.membresias where organizacion_id = p_org and activo) > v_plan.max_usuarios then
    raise exception 'Tenés más usuarios activos que los que permite el plan %. Desactivá algunos primero.', v_plan.nombre using errcode = 'P0001';
  end if;
  if not ('multi_salon' = any (v_plan.funciones)) and (select count(*) from public.salones where organizacion_id = p_org) > 1 then
    raise exception 'El plan % permite un solo salón.', v_plan.nombre using errcode = 'P0001';
  end if;
  update public.organizaciones set plan_clave = p_plan where id = p_org;
end $$;

create or replace function public.solicitar_baja_organizacion(p_org uuid, p_confirmacion text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare v_nombre text;
begin
  perform public.exigir_permiso(p_org, 'organizacion.eliminar');
  select nombre into v_nombre from public.organizaciones where id = p_org;
  if trim(coalesce(p_confirmacion, '')) <> v_nombre then
    raise exception 'Escribí el nombre exacto de la organización para confirmar.' using errcode = '22023';
  end if;
  update public.organizaciones set estado = 'baja_solicitada', baja_solicitada_at = now() where id = p_org;
  return now() + interval '30 days';
end $$;

create or replace function public.cancelar_baja_organizacion(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.exigir_permiso(p_org, 'organizacion.eliminar');
  update public.organizaciones set estado = 'activa', baja_solicitada_at = null
   where id = p_org and estado = 'baja_solicitada';
end $$;

-- Elimina definitivamente las cuentas con baja solicitada hace más de 30 días.
create or replace function public.purgar_organizaciones_dadas_de_baja()
returns int language plpgsql security definer set search_path = '' as $$
declare v_ids uuid[]; v_n int;
begin
  select array_agg(id) into v_ids from public.organizaciones
   where estado = 'baja_solicitada' and baja_solicitada_at < now() - interval '30 days';
  if v_ids is null then return 0; end if;
  update public.perfiles set organizacion_actual = null where organizacion_actual = any (v_ids);
  -- orden explícito: pagos (RESTRICT) y reservas (referencian espacios, clientes y sucursales)
  delete from public.pagos where organizacion_id = any (v_ids);
  delete from public.reservas where organizacion_id = any (v_ids);
  delete from public.organizaciones where id = any (v_ids);
  get diagnostics v_n = row_count;
  delete from public.auditoria where organizacion_id = any (v_ids);
  return v_n;
end $$;

-- -----------------------------------------------------------------------------
-- Importación (por fila, con reporte de errores)
-- -----------------------------------------------------------------------------
create or replace function public.importar_clientes(p_org uuid, p_filas jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_fila jsonb;
  v_i int := 0;
  v_ok int := 0;
  v_dup int := 0;
  v_errores jsonb := '[]'::jsonb;
  v_email text; v_tel text;
begin
  if not public.tiene_permiso(p_org, 'datos.importar') or not public.tiene_permiso(p_org, 'clientes.gestionar') then
    raise exception 'No tenés permiso para importar clientes.' using errcode = '42501';
  end if;
  if not public.org_tiene_funcion(p_org, 'importacion') then
    raise exception 'La importación no está incluida en tu plan.' using errcode = 'P0001', hint = 'LIMITE_PLAN';
  end if;
  if jsonb_array_length(p_filas) > 5000 then
    raise exception 'Importá como máximo 5000 filas por vez.' using errcode = '22023';
  end if;
  for v_fila in select * from jsonb_array_elements(p_filas) loop
    v_i := v_i + 1;
    begin
      v_email := nullif(lower(trim(v_fila->>'email')), '');
      v_tel := nullif(regexp_replace(coalesce(v_fila->>'telefono', ''), '[^0-9+]', '', 'g'), '');
      if exists (select 1 from public.clientes c where c.organizacion_id = p_org
                   and ((v_email is not null and lower(c.email) = v_email)
                     or (v_tel is not null and regexp_replace(coalesce(c.telefono, ''), '[^0-9+]', '', 'g') = v_tel))) then
        v_dup := v_dup + 1;
        continue;
      end if;
      insert into public.clientes (organizacion_id, tipo, nombre, documento, email, telefono, direccion, origen, notas, creado_por)
      values (p_org,
              case when lower(v_fila->>'tipo') = 'empresa' then 'empresa' else 'persona' end,
              trim(v_fila->>'nombre'), nullif(trim(v_fila->>'documento'), ''), v_email, nullif(trim(v_fila->>'telefono'), ''),
              nullif(trim(v_fila->>'direccion'), ''), null, nullif(trim(v_fila->>'notas'), ''), auth.uid());
      v_ok := v_ok + 1;
    exception when others then
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'error',
        case when sqlstate = '23514' and sqlerrm like '%nombre%' then 'El nombre es obligatorio (mínimo 2 caracteres).'
             when sqlstate = '23514' and sqlerrm like '%email%' then 'El email no es válido.'
             else sqlerrm end);
    end;
  end loop;
  return jsonb_build_object('importados', v_ok, 'duplicados', v_dup, 'errores', v_errores);
end $$;

create or replace function public.importar_reservas(p_org uuid, p_filas jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_fila jsonb;
  v_i int := 0;
  v_ok int := 0;
  v_errores jsonb := '[]'::jsonb;
  v_tz text;
  v_esp public.espacios;
  v_cliente uuid;
  v_fecha date;
  v_hi time; v_hf time;
  v_ini timestamptz; v_fin timestamptz;
  v_estado public.estado_reserva;
  v_tel text;
  v_reserva uuid;
begin
  if not public.tiene_permiso(p_org, 'datos.importar') or not public.tiene_permiso(p_org, 'reservas.crear') then
    raise exception 'No tenés permiso para importar reservas.' using errcode = '42501';
  end if;
  if not public.org_tiene_funcion(p_org, 'importacion') then
    raise exception 'La importación no está incluida en tu plan.' using errcode = 'P0001', hint = 'LIMITE_PLAN';
  end if;
  if jsonb_array_length(p_filas) > 2000 then
    raise exception 'Importá como máximo 2000 reservas por vez.' using errcode = '22023';
  end if;
  select zona_horaria into v_tz from public.organizaciones where id = p_org;

  for v_fila in select * from jsonb_array_elements(p_filas) loop
    v_i := v_i + 1;
    begin
      select * into v_esp from public.espacios
       where organizacion_id = p_org and public.normalizar(nombre) = public.normalizar(trim(v_fila->>'espacio')) and activo
       limit 1;
      if not found then
        raise exception 'No existe el espacio "%".', v_fila->>'espacio' using errcode = 'P0001';
      end if;
      if coalesce(v_fila->>'fecha', '') !~ '^\d{1,2}/\d{1,2}/\d{4}$' then
        raise exception 'La fecha debe tener formato DD/MM/AAAA.' using errcode = 'P0001';
      end if;
      v_fecha := to_date(v_fila->>'fecha', 'DD/MM/YYYY');
      v_hi := coalesce(nullif(v_fila->>'hora_inicio', ''), '20:00')::time;
      v_hf := coalesce(nullif(v_fila->>'hora_fin', ''), '04:00')::time;
      v_ini := (v_fecha + v_hi) at time zone v_tz;
      v_fin := (v_fecha + v_hf + case when v_hf <= v_hi then interval '1 day' else interval '0' end) at time zone v_tz;
      v_estado := case public.normalizar(coalesce(v_fila->>'estado', 'confirmada'))
                    when 'consulta' then 'consulta' when 'tentativa' then 'tentativa'
                    when 'senada' then 'senada' when 'confirmada' then 'confirmada'
                    when 'finalizada' then 'finalizada' when 'cancelada' then 'cancelada'
                    else null end;
      if v_estado is null then
        raise exception 'Estado desconocido "%".', v_fila->>'estado' using errcode = 'P0001';
      end if;

      v_tel := nullif(regexp_replace(coalesce(v_fila->>'telefono', ''), '[^0-9+]', '', 'g'), '');
      select id into v_cliente from public.clientes c
       where c.organizacion_id = p_org
         and (public.normalizar(c.nombre) = public.normalizar(trim(v_fila->>'cliente'))
              and (v_tel is null or regexp_replace(coalesce(c.telefono, ''), '[^0-9+]', '', 'g') = v_tel))
       limit 1;
      if v_cliente is null then
        insert into public.clientes (organizacion_id, nombre, telefono, email, creado_por)
        values (p_org, trim(v_fila->>'cliente'), nullif(trim(v_fila->>'telefono'), ''), nullif(lower(trim(v_fila->>'email')), ''), auth.uid())
        returning id into v_cliente;
      end if;

      v_reserva := public.guardar_reserva(p_org, null, jsonb_build_object(
          'sucursal_id', v_esp.sucursal_id, 'cliente_id', v_cliente,
          'titulo', coalesce(nullif(trim(v_fila->>'titulo'), ''), 'Evento de ' || trim(v_fila->>'cliente')),
          'tipo_evento', coalesce(nullif(v_fila->>'tipo_evento', ''), 'otro'),
          'estado', v_estado, 'inicio', v_ini, 'fin', v_fin,
          'invitados', nullif(v_fila->>'invitados', ''),
          'precio_total', nullif(replace(replace(coalesce(v_fila->>'precio', ''), '.', ''), ',', '.'), ''),
          'notas', v_fila->>'notas'),
        jsonb_build_array(jsonb_build_object('espacio_id', v_esp.id)));
      -- la capacidad se valida al final: se fuerza aquí para que el error quede en esta fila
      set constraints public.reservas_capacidad, public.reserva_espacios_capacidad immediate;
      set constraints public.reservas_capacidad, public.reserva_espacios_capacidad deferred;
      v_ok := v_ok + 1;
    exception when others then
      v_cliente := null;
      v_errores := v_errores || jsonb_build_object('fila', v_i, 'error', sqlerrm);
    end;
    v_cliente := null;
  end loop;
  return jsonb_build_object('importados', v_ok, 'errores', v_errores);
end $$;

-- -----------------------------------------------------------------------------
-- Datos de ejemplo (identificados con es_ejemplo y removibles)
-- -----------------------------------------------------------------------------
create or replace function public.cargar_datos_ejemplo(p_org uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_tz text;
  v_hoy date;
  v_salon uuid; v_suc uuid;
  v_esp1 uuid; v_esp2 uuid;
  v_c uuid[] := '{}';
  v_cid uuid;
  v_r uuid;
  v_n int := 0;
  v_def record;
begin
  perform public.exigir_permiso(p_org, 'sedes.gestionar');
  select zona_horaria into v_tz from public.organizaciones where id = p_org;
  v_hoy := (now() at time zone v_tz)::date;
  -- valida capacidad en el momento para poder omitir el ejemplo que no entre
  set constraints public.reservas_capacidad, public.reserva_espacios_capacidad immediate;

  -- Reutiliza la primera sucursal existente con espacios; si no hay, crea una sede de ejemplo.
  select s.id into v_suc from public.sucursales s
   where s.organizacion_id = p_org and s.activo
     and exists (select 1 from public.espacios e where e.sucursal_id = s.id and e.activo)
   order by s.creado_at limit 1;
  if v_suc is null then
    select id into v_salon from public.salones where organizacion_id = p_org order by creado_at limit 1;
    if v_salon is null then
      insert into public.salones (organizacion_id, nombre, es_ejemplo) values (p_org, 'Salón de ejemplo', true) returning id into v_salon;
    end if;
    select id into v_suc from public.sucursales where organizacion_id = p_org and activo order by creado_at limit 1;
    if v_suc is null then
      insert into public.sucursales (organizacion_id, salon_id, nombre, direccion, localidad, provincia, es_ejemplo)
      values (p_org, v_salon, 'Sede de ejemplo', 'Av. Siempre Viva 742', 'Córdoba', 'Córdoba', true) returning id into v_suc;
    end if;
    insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima, color, es_ejemplo)
    values (p_org, v_suc, 'Salón principal', 'salon', 180, '#7c3aed', true) returning id into v_esp1;
    insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima, color, montaje_min, limpieza_min, es_ejemplo)
    values (p_org, v_suc, 'Quincho', 'quincho', 50, '#0d9488', 30, 30, true) returning id into v_esp2;
  else
    select id into v_esp1 from public.espacios where sucursal_id = v_suc and activo order by capacidad_maxima desc, creado_at limit 1;
    select id into v_esp2 from public.espacios where sucursal_id = v_suc and activo and id <> v_esp1 order by creado_at limit 1;
    v_esp2 := coalesce(v_esp2, v_esp1);
  end if;

  insert into public.clientes (organizacion_id, nombre, telefono, email, origen, es_ejemplo) values
    (p_org, 'Lucía Fernández',    '+54 9 351 555-0101', 'lucia.ejemplo@example.com',  'instagram', true),
    (p_org, 'Martín Gómez',       '+54 9 351 555-0102', 'martin.ejemplo@example.com', 'whatsapp', true),
    (p_org, 'Estudio Contable Ríos', '+54 351 555-0103', 'rrhh.ejemplo@example.com',  'web', true),
    (p_org, 'Carla y Diego',      '+54 9 351 555-0104', 'carla.ejemplo@example.com',  'recomendacion', true);
  select array_agg(id order by creado_at, nombre) into v_c from public.clientes where organizacion_id = p_org and es_ejemplo;

  for v_def in
    select * from (values
      (1, 'Cumpleaños de 15 de Sofía', 'quince',      'confirmada', 12, '21:00'::time, '05:00'::time, 150, 4500000, 1),
      (2, 'Casamiento Carla y Diego',  'casamiento',  'senada',     26, '20:30'::time, '05:30'::time, 170, 7800000, 1),
      (3, 'Fin de año Estudio Ríos',   'corporativo', 'tentativa',  40, '20:00'::time, '01:00'::time,  45, 1600000, 2),
      (4, 'Cumpleaños de Martín',      'cumpleanos',  'consulta',   19, '13:00'::time, '19:00'::time,  35,  900000, 2),
      (5, 'Bautismo familia Gómez',    'bautismo',    'finalizada', -9, '12:00'::time, '18:00'::time,  40, 1100000, 2),
      (6, 'Evento de hoy (ejemplo)',   'infantil',    'confirmada',  0, '17:00'::time, '21:00'::time,  30,  650000, 2)
    ) as t(i, titulo, tipo, estado, dias, hi, hf, inv, precio, esp)
  loop
    begin
      v_cid := v_c[1 + ((v_def.i - 1) % 4)];
      insert into public.reservas (organizacion_id, sucursal_id, cliente_id, titulo, tipo_evento, estado, inicio, fin,
                                   invitados, precio_total, contrato_estado, es_ejemplo, creado_por)
      values (p_org, v_suc, v_cid, v_def.titulo, v_def.tipo, 'consulta',
              (v_hoy + v_def.dias + v_def.hi) at time zone v_tz,
              (v_hoy + v_def.dias + v_def.hf + case when v_def.hf <= v_def.hi then interval '1 day' else interval '0' end) at time zone v_tz,
              v_def.inv, v_def.precio,
              case when v_def.estado in ('confirmada','finalizada') then 'firmado'::public.estado_contrato else 'pendiente' end,
              true, auth.uid())
      returning id into v_r;
      insert into public.reserva_espacios (organizacion_id, reserva_id, espacio_id)
      values (p_org, v_r, case when v_def.esp = 1 then v_esp1 else v_esp2 end);
      update public.reservas set estado = v_def.estado::public.estado_reserva where id = v_r;

      if v_def.estado in ('senada','confirmada','finalizada') then
        insert into public.pagos (organizacion_id, reserva_id, fecha, monto, medio, concepto, registrado_por)
        values (p_org, v_r, v_hoy - 20, round(v_def.precio * 0.3), 'transferencia', 'sena', auth.uid());
        insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto) values
          (p_org, v_r, 'Seña', v_hoy - 20, round(v_def.precio * 0.3)),
          (p_org, v_r, 'Segunda cuota', v_hoy + least(v_def.dias, 7) - 10, round(v_def.precio * 0.3)),
          (p_org, v_r, 'Saldo', v_hoy + v_def.dias - 3, v_def.precio - 2 * round(v_def.precio * 0.3));
      end if;
      if v_def.estado = 'confirmada' and v_def.dias > 0 then
        insert into public.tareas (organizacion_id, reserva_id, titulo, vence_el, prioridad, asignada_a, es_ejemplo, creado_por)
        values (p_org, v_r, 'Confirmar menú y cantidad final de invitados', v_hoy + v_def.dias - 7, 'alta', auth.uid(), true, auth.uid());
      end if;
      v_n := v_n + 1;
    exception when exclusion_violation or check_violation then
      null;  -- la fecha choca con una reserva real: se omite este ejemplo
    end;
  end loop;

  insert into public.gastos (organizacion_id, sucursal_id, fecha, categoria, descripcion, proveedor, monto, es_ejemplo, registrado_por) values
    (p_org, v_suc, v_hoy - 5, 'limpieza', 'Servicio de limpieza post evento (ejemplo)', 'Limpiezas del Centro', 85000, true, auth.uid()),
    (p_org, v_suc, v_hoy - 2, 'servicios', 'Factura de luz (ejemplo)', 'Distribuidora eléctrica', 230000, true, auth.uid());
  insert into public.tareas (organizacion_id, titulo, vence_el, prioridad, es_ejemplo, creado_por)
  values (p_org, 'Revisar matafuegos y salidas de emergencia (ejemplo)', v_hoy + 3, 'media', true, auth.uid());

  return jsonb_build_object('reservas', v_n);
end $$;

create or replace function public.borrar_datos_ejemplo(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.exigir_permiso(p_org, 'sedes.gestionar');
  delete from public.tareas where organizacion_id = p_org and es_ejemplo;
  delete from public.gastos where organizacion_id = p_org and es_ejemplo;
  delete from public.pagos where reserva_id in (select id from public.reservas where organizacion_id = p_org and es_ejemplo);
  delete from public.reservas where organizacion_id = p_org and es_ejemplo;
  delete from public.clientes c where c.organizacion_id = p_org and c.es_ejemplo
     and not exists (select 1 from public.reservas r where r.cliente_id = c.id);
  delete from public.espacios e where e.organizacion_id = p_org and e.es_ejemplo
     and not exists (select 1 from public.reserva_espacios re where re.espacio_id = e.id);
  delete from public.sucursales s where s.organizacion_id = p_org and s.es_ejemplo
     and not exists (select 1 from public.espacios e where e.sucursal_id = s.id)
     and not exists (select 1 from public.reservas r where r.sucursal_id = s.id);
  delete from public.salones sa where sa.organizacion_id = p_org and sa.es_ejemplo
     and not exists (select 1 from public.sucursales s where s.salon_id = sa.id);
end $$;

-- -----------------------------------------------------------------------------
-- Checklist de configuración inicial (derivado de datos reales)
-- -----------------------------------------------------------------------------
create or replace function public.checklist_configuracion(p_org uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'datos_organizacion', exists (select 1 from public.organizaciones where id = p_org and (cuit is not null or telefono is not null)),
    'sucursal',  exists (select 1 from public.sucursales where organizacion_id = p_org and not es_ejemplo),
    'espacio',   exists (select 1 from public.espacios where organizacion_id = p_org and not es_ejemplo),
    'horarios',  exists (select 1 from public.espacio_horarios where organizacion_id = p_org),
    'equipo',    (select count(*) from public.membresias where organizacion_id = p_org) > 1
                  or exists (select 1 from public.invitaciones where organizacion_id = p_org),
    'cliente',   exists (select 1 from public.clientes where organizacion_id = p_org and not es_ejemplo),
    'reserva',   exists (select 1 from public.reservas where organizacion_id = p_org and not es_ejemplo),
    'datos_ejemplo', exists (select 1 from public.reservas where organizacion_id = p_org and es_ejemplo)
  )
$$;

-- -----------------------------------------------------------------------------
-- Privilegios: con auto_expose desactivado, todo se otorga explícitamente.
-- -----------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on public.ocupaciones, public.auditoria, public.planes, public.permisos,
  public.roles_plantilla, public.organizaciones from authenticated;
grant update on public.organizaciones to authenticated;
revoke insert, delete on public.membresias from authenticated;
grant execute on all functions in schema public to authenticated;

revoke execute on function public.upsert_ocupacion(uuid, uuid, tstzrange, boolean, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.sincronizar_ocupaciones_reserva(uuid) from public, anon, authenticated;
revoke execute on function public.vencer_tentativas() from public, anon, authenticated;
revoke execute on function public.finalizar_eventos_pasados() from public, anon, authenticated;
revoke execute on function public.purgar_organizaciones_dadas_de_baja() from public, anon, authenticated;
revoke execute on function public.ver_invitacion(text) from public;
grant execute on function public.ver_invitacion(text) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Tareas programadas (pg_cron, si está disponible en la instancia)
-- -----------------------------------------------------------------------------
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('festy_vencer_tentativas', '*/15 * * * *', 'select public.vencer_tentativas()');
  perform cron.schedule('festy_finalizar_eventos', '7 * * * *', 'select public.finalizar_eventos_pasados()');
  perform cron.schedule('festy_purgar_bajas', '30 4 * * *', 'select public.purgar_organizaciones_dadas_de_baja()');
exception when others then
  raise warning 'pg_cron no disponible (%): programar vencer_tentativas, finalizar_eventos_pasados y purgar_organizaciones_dadas_de_baja externamente.', sqlerrm;
end $$;
