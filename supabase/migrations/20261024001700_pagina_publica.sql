-- =============================================================================
-- Festy · Migración 17: página pública del salón con pedido de fecha.
--
-- Cada organización puede publicar una página (festy…/s/<slug>) con su
-- descripción, sedes, espacios y un calendario de disponibilidad. El visitante
-- elige espacio y fecha y deja sus datos: se crea un cliente (origen web) y una
-- CONSULTA (no bloquea la fecha), y se avisa al equipo. Después puede escribir
-- por WhatsApp al salón con el pedido ya armado.
-- Lo público solo expone: datos de presentación, espacios activos y qué días
-- están ocupados (sin nombres ni detalles de otros eventos).
-- =============================================================================

alter table public.organizaciones
  add column pagina_slug        text unique check (pagina_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(pagina_slug) between 3 and 40),
  add column pagina_activa      boolean not null default false,
  add column pagina_descripcion text check (pagina_descripcion is null or length(pagina_descripcion) <= 2000),
  add column pagina_whatsapp    text check (pagina_whatsapp is null or pagina_whatsapp ~ '^\d{8,15}$'),
  add check (not pagina_activa or pagina_slug is not null);

create or replace function api.sp_pagina_guardar(p_org uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  perform public.exigir_permiso(p_org, 'organizacion.editar');
  update public.organizaciones set
    pagina_slug = nullif(lower(trim(coalesce(p_datos->>'pagina_slug', ''))), ''),
    pagina_activa = coalesce((p_datos->>'pagina_activa')::boolean, false),
    pagina_descripcion = nullif(trim(coalesce(p_datos->>'pagina_descripcion', '')), ''),
    pagina_whatsapp = nullif(regexp_replace(coalesce(p_datos->>'pagina_whatsapp', ''), '\D', '', 'g'), '')
   where id = p_org
  returning jsonb_build_object('pagina_slug', pagina_slug, 'pagina_activa', pagina_activa,
                               'pagina_descripcion', pagina_descripcion, 'pagina_whatsapp', pagina_whatsapp) into v;
  if v is null then raise exception 'No se encontró la organización o no tenés permiso.' using errcode = '42501'; end if;
  return v;
exception when unique_violation then
  raise exception 'Esa dirección ya la usa otro salón. Probá con otra.' using errcode = '23505';
end $$;

-- Organización publicada por su slug (o error si no existe / no está activa).
create or replace function public.organizacion_publica(p_slug text)
returns public.organizaciones language plpgsql stable security definer set search_path = '' as $$
declare v public.organizaciones;
begin
  select * into v from public.organizaciones
   where pagina_slug = lower(p_slug) and pagina_activa and estado = 'activa';
  if not found then raise exception 'Esta página no existe o no está publicada.' using errcode = 'P0002'; end if;
  return v;
end $$;
revoke execute on function public.organizacion_publica(text) from public, anon, authenticated;

create or replace function api.sp_publico_salon(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_o public.organizaciones := public.organizacion_publica(p_slug);
begin
  return jsonb_build_object(
    'nombre', v_o.nombre, 'descripcion', v_o.pagina_descripcion, 'logo', v_o.logo, 'color_marca', v_o.color_marca,
    'whatsapp', v_o.pagina_whatsapp, 'telefono', v_o.telefono, 'email', v_o.email_contacto, 'direccion', v_o.direccion,
    'zona_horaria', v_o.zona_horaria,
    'sedes', (select api.lista(jsonb_agg(jsonb_build_object('id', s.id, 'nombre', s.nombre, 'direccion', s.direccion,
                 'localidad', s.localidad, 'provincia', s.provincia) order by s.nombre))
                from public.sucursales s where s.organizacion_id = v_o.id and s.activo),
    'espacios', (select api.lista(jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'tipo', e.tipo, 'descripcion', e.descripcion,
                    'capacidad_maxima', e.capacidad_maxima, 'capacidad_minima', e.capacidad_minima, 'sucursal_id', e.sucursal_id, 'color', e.color)
                    order by e.nombre))
                   from public.espacios e join public.sucursales s on s.id = e.sucursal_id
                  where e.organizacion_id = v_o.id and e.activo and s.activo));
end $$;

-- Días ocupados por espacio (reservas que bloquean y bloqueos). Máximo 93 días.
create or replace function api.sp_publico_ocupacion(p_slug text, p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_o public.organizaciones := public.organizacion_publica(p_slug);
begin
  if p_hasta < p_desde or p_hasta - p_desde > 93 then
    raise exception 'Rango de fechas inválido.' using errcode = '22023';
  end if;
  return (
    select api.lista(jsonb_agg(distinct jsonb_build_object('fecha', d.dia::date, 'espacio_id', x.espacio_id)))
      from generate_series(p_desde, p_hasta, interval '1 day') d(dia)
      join (
        select re.espacio_id, tstzrange(r.inicio, r.fin) as rango
          from public.reservas r join public.reserva_espacios re on re.reserva_id = r.id
         where r.organizacion_id = v_o.id and public.estado_bloquea(r.estado)
           and r.fin > (p_desde::timestamp at time zone v_o.zona_horaria) and r.inicio < ((p_hasta + 1)::timestamp at time zone v_o.zona_horaria)
        union all
        select b.espacio_id, tstzrange(b.inicio, b.fin)
          from public.bloqueos b
         where b.organizacion_id = v_o.id
           and b.fin > (p_desde::timestamp at time zone v_o.zona_horaria) and b.inicio < ((p_hasta + 1)::timestamp at time zone v_o.zona_horaria)
      ) x on public.ocupa_dia(x.rango, d.dia::date, v_o.zona_horaria)
  );
end $$;

-- Pedido de fecha desde la página: cliente (origen web) + consulta + aviso al equipo.
create or replace function api.sp_publico_pedido(p_slug text, p_datos jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_o public.organizaciones := public.organizacion_publica(p_slug);
  v_nombre text := trim(coalesce(p_datos->>'nombre', ''));
  v_tel text := regexp_replace(coalesce(p_datos->>'telefono', ''), '\D', '', 'g');
  v_email text := nullif(lower(trim(coalesce(p_datos->>'email', ''))), '');
  v_fecha date := (p_datos->>'fecha')::date;
  v_tipo text := coalesce(nullif(p_datos->>'tipo_evento', ''), 'otro');
  v_inv int := nullif(p_datos->>'invitados', '')::int;
  v_hi time := coalesce(nullif(p_datos->>'hora_inicio', ''), '21:00')::time;
  v_hf time := coalesce(nullif(p_datos->>'hora_fin', ''), '04:00')::time;
  v_msg text := left(trim(coalesce(p_datos->>'mensaje', '')), 1000);
  v_hoy date := (now() at time zone v_o.zona_horaria)::date;
  v_e public.espacios;
  v_cliente uuid;
  v_reserva public.reservas;
  v_inicio timestamptz;
  v_fin timestamptz;
begin
  if length(v_nombre) < 2 or length(v_nombre) > 120 then raise exception 'Ingresá tu nombre.' using errcode = '23514'; end if;
  if length(v_tel) < 8 or length(v_tel) > 15 then raise exception 'Ingresá un teléfono válido (con código de área).' using errcode = '23514'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'El email no es válido.' using errcode = '23514'; end if;
  if v_fecha is null or v_fecha < v_hoy or v_fecha > v_hoy + 730 then raise exception 'Elegí una fecha desde hoy y dentro de los próximos dos años.' using errcode = '23514'; end if;
  select * into v_e from public.espacios where id = nullif(p_datos->>'espacio_id', '')::uuid and organizacion_id = v_o.id and activo;
  if not found then raise exception 'Elegí un espacio.' using errcode = '23514'; end if;
  if v_inv is not null and (v_inv < 1 or v_inv > 100000) then raise exception 'La cantidad de invitados no es válida.' using errcode = '23514'; end if;

  -- Límites contra abuso: por salón y por teléfono, en las últimas 24 h.
  if (select count(*) from public.clientes c join public.reservas r on r.cliente_id = c.id
       where r.organizacion_id = v_o.id and c.origen = 'web' and r.creado_at > now() - interval '1 day' and r.creado_por is null) >= 30 then
    raise exception 'Recibimos muchos pedidos hoy. Escribinos por WhatsApp o probá mañana.' using errcode = 'P0001';
  end if;
  if (select count(*) from public.reservas r join public.clientes c on c.id = r.cliente_id
       where r.organizacion_id = v_o.id and regexp_replace(coalesce(c.telefono, ''), '\D', '', 'g') = v_tel
         and r.creado_at > now() - interval '1 day' and r.creado_por is null) >= 3 then
    raise exception 'Ya recibimos tus pedidos. Te vamos a contactar.' using errcode = 'P0001';
  end if;

  select id into v_cliente from public.clientes
   where organizacion_id = v_o.id and regexp_replace(coalesce(telefono, ''), '\D', '', 'g') = v_tel
   order by creado_at limit 1;
  if v_cliente is null then
    insert into public.clientes (organizacion_id, nombre, telefono, email, origen, notas)
    values (v_o.id, v_nombre, v_tel, v_email, 'web', 'Llegó por la página web.')
    returning id into v_cliente;
  end if;

  v_inicio := (v_fecha + v_hi) at time zone v_o.zona_horaria;
  v_fin := (case when v_hf <= v_hi then v_fecha + 1 else v_fecha end + v_hf) at time zone v_o.zona_horaria;
  insert into public.reservas (organizacion_id, sucursal_id, cliente_id, titulo, tipo_evento, estado, inicio, fin, invitados, notas)
  values (v_o.id, v_e.sucursal_id, v_cliente, left('Pedido web · ' || v_nombre, 160),
          case when v_tipo in ('casamiento','quince','cumpleanos','infantil','corporativo','egresados','bautismo','comunion','aniversario','conferencia','otro')
               then v_tipo else 'otro' end,
          'consulta', v_inicio, v_fin, v_inv,
          concat_ws(E'\n', 'Pedido desde la página web.', nullif('Teléfono: ' || v_tel, 'Teléfono: '), 'Email: ' || v_email, nullif(v_msg, '')))
  returning * into v_reserva;
  insert into public.reserva_espacios (organizacion_id, reserva_id, espacio_id) values (v_o.id, v_reserva.id, v_e.id);

  perform public.notificar(v_o.id, array(select public.usuarios_con_permiso(v_o.id, 'reservas.ver')), 'pedido_web',
    'Nuevo pedido de fecha desde tu página',
    format('%s · %s · %s', v_nombre, to_char(v_fecha, 'DD/MM/YYYY'), v_e.nombre),
    format('/reservas/%s', v_reserva.id));
  return jsonb_build_object('ok', true, 'numero', v_reserva.numero);
end $$;

revoke execute on function api.sp_publico_salon(text), api.sp_publico_ocupacion(text, date, date), api.sp_publico_pedido(text, jsonb) from public;
grant execute on function api.sp_publico_salon(text), api.sp_publico_ocupacion(text, date, date), api.sp_publico_pedido(text, jsonb) to anon, authenticated;
revoke execute on function api.sp_pagina_guardar(uuid, jsonb) from public, anon;
grant execute on function api.sp_pagina_guardar(uuid, jsonb) to authenticated;
