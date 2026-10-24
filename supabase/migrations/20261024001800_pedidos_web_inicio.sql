-- =============================================================================
-- Festy · Migración 18: pedidos de la página web en el Inicio.
--
-- La reserva creada desde la página pública guarda los datos del pedido
-- (nombre, teléfono, email, mensaje) en pedido_web. El Inicio lista los pedidos
-- sin atender para contactar por teléfono o WhatsApp; "Ya lo contacté" los
-- marca como atendidos. También dejan de estar pendientes si la consulta pasa
-- a otro estado o la fecha ya pasó.
-- =============================================================================

alter table public.reservas add column pedido_web jsonb;
create index reservas_pedidos_web_idx on public.reservas (organizacion_id) where pedido_web is not null and pedido_web->>'atendido_at' is null;

-- Pedidos anteriores a esta migración (se reconocen por el título que les puso la página).
update public.reservas r set pedido_web = jsonb_build_object(
    'nombre', c.nombre, 'telefono', c.telefono, 'email', c.email, 'mensaje', null, 'recibido_at', r.creado_at)
  from public.clientes c
 where c.id = r.cliente_id and r.titulo like 'Pedido web · %' and r.creado_por is null and r.pedido_web is null;

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
  insert into public.reservas (organizacion_id, sucursal_id, cliente_id, titulo, tipo_evento, estado, inicio, fin, invitados, notas, pedido_web)
  values (v_o.id, v_e.sucursal_id, v_cliente, left('Pedido web · ' || v_nombre, 160),
          case when v_tipo in ('casamiento','quince','cumpleanos','infantil','corporativo','egresados','bautismo','comunion','aniversario','conferencia','otro')
               then v_tipo else 'otro' end,
          'consulta', v_inicio, v_fin, v_inv,
          concat_ws(E'\n', 'Pedido desde la página web.', nullif('Teléfono: ' || v_tel, 'Teléfono: '), 'Email: ' || v_email, nullif(v_msg, '')),
          jsonb_build_object('nombre', v_nombre, 'telefono', v_tel, 'email', v_email, 'mensaje', nullif(v_msg, ''), 'recibido_at', now()))
  returning * into v_reserva;
  insert into public.reserva_espacios (organizacion_id, reserva_id, espacio_id) values (v_o.id, v_reserva.id, v_e.id);

  perform public.notificar(v_o.id, array(select public.usuarios_con_permiso(v_o.id, 'reservas.ver')), 'pedido_web',
    'Nuevo pedido de fecha desde tu página',
    format('%s · %s · %s', v_nombre, to_char(v_fecha, 'DD/MM/YYYY'), v_e.nombre),
    format('/reservas/%s', v_reserva.id));
  return jsonb_build_object('ok', true, 'numero', v_reserva.numero);
end $$;

-- Pedidos de la página sin atender (consultas con fecha futura).
create or replace function api.sp_pedidos_web_pendientes(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object(
           'id', r.id, 'numero', r.numero, 'inicio', r.inicio, 'fin', r.fin, 'invitados', r.invitados, 'tipo_evento', r.tipo_evento,
           'nombre', coalesce(r.pedido_web->>'nombre', c.nombre), 'telefono', coalesce(r.pedido_web->>'telefono', c.telefono),
           'email', coalesce(r.pedido_web->>'email', c.email), 'mensaje', r.pedido_web->>'mensaje', 'recibido_at', r.pedido_web->>'recibido_at',
           'espacio', (select e.nombre from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id where re.reserva_id = r.id limit 1))
           order by r.pedido_web->>'recibido_at' desc))
    from public.reservas r left join public.clientes c on c.id = r.cliente_id
   where r.organizacion_id = p_org and r.pedido_web is not null and r.pedido_web->>'atendido_at' is null
     and r.estado = 'consulta' and r.fin > now()
$$;

-- "Ya lo contacté": requiere poder editar reservas.
create or replace function api.sp_pedido_web_atendido(p_reserva uuid)
returns void language plpgsql set search_path = '' as $$
begin
  update public.reservas set pedido_web = pedido_web || jsonb_build_object('atendido_at', now(), 'atendido_por', auth.uid())
   where id = p_reserva and pedido_web is not null;
  if not found then raise exception 'No se encontró el pedido o no tenés permiso.' using errcode = '42501'; end if;
end $$;

revoke execute on function api.sp_pedidos_web_pendientes(uuid), api.sp_pedido_web_atendido(uuid) from public, anon;
grant execute on function api.sp_pedidos_web_pendientes(uuid), api.sp_pedido_web_atendido(uuid) to authenticated;
revoke execute on function api.sp_publico_pedido(text, jsonb) from public;
grant execute on function api.sp_publico_pedido(text, jsonb) to anon, authenticated;
