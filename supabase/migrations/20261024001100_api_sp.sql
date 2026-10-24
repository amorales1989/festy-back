-- =============================================================================
-- Festy · Migración 11: capa de stored procedures (esquema api).
--
-- La API Node es el único cliente de la base y SOLO ejecuta funciones de este
-- esquema (api.sp_*). Cada SP:
--   * es SECURITY INVOKER: corre con el rol del usuario (authenticated) y su
--     identidad (request.jwt.claims), así que la RLS, los permisos por rol y el
--     aislamiento entre organizaciones siguen aplicando dentro del SP;
--   * devuelve jsonb con la forma que consume el front.
-- Las reglas de negocio existentes (guardar_reserva, registrar_pago, etc.) se
-- reutilizan: los SP las envuelven.
-- =============================================================================

create schema if not exists api;
grant usage on schema api to authenticated, anon, service_role;

-- Ayudante: lista vacía en lugar de null
create or replace function api.lista(j jsonb) returns jsonb language sql immutable as $$ select coalesce(j, '[]'::jsonb) $$;

-- -----------------------------------------------------------------------------
-- Sesión y organización
-- -----------------------------------------------------------------------------
create or replace function api.sp_perfil_obtener()
returns jsonb language sql stable set search_path = '' as $$
  select to_jsonb(p) from public.perfiles p where p.id = auth.uid()
$$;

create or replace function api.sp_perfil_elegir_organizacion(p_org uuid)
returns void language sql set search_path = '' as $$
  update public.perfiles set organizacion_actual = p_org where id = auth.uid() and public.es_miembro(p_org)
$$;

create or replace function api.sp_organizaciones_listar()
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(o) order by o.nombre)) from public.organizaciones o
$$;

-- Todo lo que el front necesita al elegir una organización, en una sola llamada.
create or replace function api.sp_organizacion_contexto(p_org uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_org public.organizaciones;
begin
  select * into v_org from public.organizaciones where id = p_org;
  if not found then raise exception 'No tenés acceso a esta organización.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'organizacion', to_jsonb(v_org),
    'permisos', to_jsonb(public.mis_permisos(p_org)),
    'rol', (select r.nombre from public.membresias m join public.roles r on r.id = m.rol_id
             where m.organizacion_id = p_org and m.usuario_id = auth.uid()),
    'plan', (select to_jsonb(pl) from public.planes pl where pl.clave = v_org.plan_clave),
    'salones', (select api.lista(jsonb_agg(to_jsonb(s) order by s.nombre)) from public.salones s where s.organizacion_id = p_org),
    'sucursales', (select api.lista(jsonb_agg(to_jsonb(s) order by s.nombre)) from public.sucursales s where s.organizacion_id = p_org),
    'espacios', (select api.lista(jsonb_agg(to_jsonb(e) order by e.nombre)) from public.espacios e where e.organizacion_id = p_org));
end $$;

create or replace function api.sp_organizacion_crear(p_nombre text, p_zona_horaria text)
returns uuid language sql set search_path = '' as $$ select public.crear_organizacion(p_nombre, p_zona_horaria) $$;

create or replace function api.sp_organizacion_actualizar(p_org uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  update public.organizaciones o set
    nombre = case when p_datos ? 'nombre' then p_datos->>'nombre' else o.nombre end,
    razon_social = case when p_datos ? 'razon_social' then p_datos->>'razon_social' else o.razon_social end,
    cuit = case when p_datos ? 'cuit' then p_datos->>'cuit' else o.cuit end,
    email_contacto = case when p_datos ? 'email_contacto' then p_datos->>'email_contacto' else o.email_contacto end,
    telefono = case when p_datos ? 'telefono' then p_datos->>'telefono' else o.telefono end,
    direccion = case when p_datos ? 'direccion' then p_datos->>'direccion' else o.direccion end,
    zona_horaria = case when p_datos ? 'zona_horaria' then p_datos->>'zona_horaria' else o.zona_horaria end,
    horas_vencimiento_tentativa = case when p_datos ? 'horas_vencimiento_tentativa' then (p_datos->>'horas_vencimiento_tentativa')::int else o.horas_vencimiento_tentativa end,
    logo = case when p_datos ? 'logo' then p_datos->>'logo' else o.logo end,
    color_marca = case when p_datos ? 'color_marca' then p_datos->>'color_marca' else o.color_marca end,
    condiciones_presupuesto = case when p_datos ? 'condiciones_presupuesto' then p_datos->>'condiciones_presupuesto' else o.condiciones_presupuesto end,
    validez_presupuesto_dias = case when p_datos ? 'validez_presupuesto_dias' then (p_datos->>'validez_presupuesto_dias')::int else o.validez_presupuesto_dias end,
    dias_devolucion_garantia = case when p_datos ? 'dias_devolucion_garantia' then (p_datos->>'dias_devolucion_garantia')::int else o.dias_devolucion_garantia end
  where o.id = p_org
  returning to_jsonb(o) into v;
  if v is null then raise exception 'No tenés permiso para editar la organización.' using errcode = '42501'; end if;
  return v;
end $$;

create or replace function api.sp_planes_listar()
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(p) order by p.orden)) from public.planes p
$$;
create or replace function api.sp_plan_cambiar(p_org uuid, p_plan text)
returns void language sql set search_path = '' as $$ select public.cambiar_plan(p_org, p_plan) $$;
create or replace function api.sp_baja_solicitar(p_org uuid, p_confirmacion text)
returns timestamptz language sql set search_path = '' as $$ select public.solicitar_baja_organizacion(p_org, p_confirmacion) $$;
create or replace function api.sp_baja_cancelar(p_org uuid)
returns void language sql set search_path = '' as $$ select public.cancelar_baja_organizacion(p_org) $$;
create or replace function api.sp_checklist(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$ select public.checklist_configuracion(p_org) $$;
create or replace function api.sp_ejemplos_cargar(p_org uuid)
returns jsonb language sql set search_path = '' as $$ select public.cargar_datos_ejemplo(p_org) $$;
create or replace function api.sp_ejemplos_borrar(p_org uuid)
returns void language sql set search_path = '' as $$ select public.borrar_datos_ejemplo(p_org) $$;
create or replace function api.sp_panel(p_org uuid, p_desde date, p_hasta date, p_salon uuid, p_sucursal uuid, p_responsable uuid)
returns jsonb language sql set search_path = '' as $$ select public.panel_resumen(p_org, p_desde, p_hasta, p_salon, p_sucursal, p_responsable) $$;
create or replace function api.sp_buscar(p_org uuid, p_q text)
returns jsonb language sql stable set search_path = '' as $$ select public.buscar_global(p_org, p_q) $$;
create or replace function api.sp_miembros_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(m))) from public.listar_miembros(p_org) m
$$;

-- -----------------------------------------------------------------------------
-- Eliminar y activar (lista blanca de tablas; la RLS decide si se puede)
-- -----------------------------------------------------------------------------
create or replace function api.sp_eliminar(p_entidad text, p_id uuid)
returns void language plpgsql set search_path = '' as $$
declare v_n int;
begin
  if p_entidad not in ('salones','sucursales','espacios','recursos','feriados','clientes','servicios','gastos','tareas',
                       'entrevistas','presupuestos','reservas','bloqueos','cuotas','reserva_items') then
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
  if p_entidad not in ('sucursales','espacios','servicios','recursos') then
    raise exception 'Entidad no válida: %', p_entidad using errcode = '22023';
  end if;
  execute format('update public.%I set activo = $2 where id = $1', p_entidad) using p_id, p_activo;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No se encontró el registro o no tenés permiso para modificarlo.' using errcode = '42501'; end if;
end $$;

-- -----------------------------------------------------------------------------
-- Sedes: salones, sucursales, espacios, horarios, recursos y feriados
-- -----------------------------------------------------------------------------
create or replace function api.sp_salon_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  if p_id is null then
    insert into public.salones (organizacion_id, nombre, descripcion)
    values (p_org, p_datos->>'nombre', nullif(p_datos->>'descripcion', '')) returning to_jsonb(salones.*) into v;
  else
    update public.salones set nombre = p_datos->>'nombre', descripcion = nullif(p_datos->>'descripcion', '')
     where id = p_id and organizacion_id = p_org returning to_jsonb(salones.*) into v;
    if v is null then raise exception 'No se encontró el salón o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

create or replace function api.sp_sucursal_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  if p_id is null then
    insert into public.sucursales (organizacion_id, salon_id, nombre, direccion, localidad, provincia, telefono)
    values (p_org, (p_datos->>'salon_id')::uuid, p_datos->>'nombre', nullif(p_datos->>'direccion', ''), nullif(p_datos->>'localidad', ''),
            nullif(p_datos->>'provincia', ''), nullif(p_datos->>'telefono', ''))
    returning to_jsonb(sucursales.*) into v;
  else
    update public.sucursales set salon_id = (p_datos->>'salon_id')::uuid, nombre = p_datos->>'nombre',
           direccion = nullif(p_datos->>'direccion', ''), localidad = nullif(p_datos->>'localidad', ''),
           provincia = nullif(p_datos->>'provincia', ''), telefono = nullif(p_datos->>'telefono', '')
     where id = p_id and organizacion_id = p_org returning to_jsonb(sucursales.*) into v;
    if v is null then raise exception 'No se encontró la sede o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

-- Guarda el espacio y, si se envían, reemplaza sus horarios (todo en una transacción).
create or replace function api.sp_espacio_guardar(p_org uuid, p_id uuid, p_datos jsonb, p_horarios jsonb default null)
returns jsonb language plpgsql set search_path = '' as $$
declare v_id uuid := p_id; v jsonb;
begin
  if v_id is null then
    insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, descripcion, capacidad_maxima, capacidad_minima, garantia_sugerida, color,
                                 preparacion_min, montaje_min, desmontaje_min, limpieza_min, duracion_minima_min, duracion_sugerida_min)
    values (p_org, (p_datos->>'sucursal_id')::uuid, p_datos->>'nombre', coalesce(p_datos->>'tipo', 'salon'), nullif(p_datos->>'descripcion', ''),
            (p_datos->>'capacidad_maxima')::int, nullif(p_datos->>'capacidad_minima', '')::int, coalesce(nullif(p_datos->>'garantia_sugerida', '')::numeric, 0),
            coalesce(p_datos->>'color', '#7c3aed'), coalesce((p_datos->>'preparacion_min')::int, 0), coalesce((p_datos->>'montaje_min')::int, 60),
            coalesce((p_datos->>'desmontaje_min')::int, 60), coalesce((p_datos->>'limpieza_min')::int, 60),
            coalesce((p_datos->>'duracion_minima_min')::int, 60), coalesce((p_datos->>'duracion_sugerida_min')::int, 300))
    returning id into v_id;
  else
    update public.espacios set sucursal_id = (p_datos->>'sucursal_id')::uuid, nombre = p_datos->>'nombre', tipo = coalesce(p_datos->>'tipo', tipo),
           descripcion = nullif(p_datos->>'descripcion', ''), capacidad_maxima = (p_datos->>'capacidad_maxima')::int,
           capacidad_minima = nullif(p_datos->>'capacidad_minima', '')::int, garantia_sugerida = coalesce(nullif(p_datos->>'garantia_sugerida', '')::numeric, 0),
           color = coalesce(p_datos->>'color', color), preparacion_min = coalesce((p_datos->>'preparacion_min')::int, preparacion_min),
           montaje_min = coalesce((p_datos->>'montaje_min')::int, montaje_min), desmontaje_min = coalesce((p_datos->>'desmontaje_min')::int, desmontaje_min),
           limpieza_min = coalesce((p_datos->>'limpieza_min')::int, limpieza_min),
           duracion_minima_min = coalesce((p_datos->>'duracion_minima_min')::int, duracion_minima_min),
           duracion_sugerida_min = coalesce((p_datos->>'duracion_sugerida_min')::int, duracion_sugerida_min)
     where id = v_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró el espacio o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  if p_horarios is not null then
    perform public.guardar_horarios(v_id, p_horarios);
  end if;
  select to_jsonb(e) into v from public.espacios e where e.id = v_id;
  return v;
end $$;

create or replace function api.sp_espacio_horarios(p_espacio uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(h) order by h.dia_semana, h.hora_desde)) from public.espacio_horarios h where h.espacio_id = p_espacio
$$;

create or replace function api.sp_recursos_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(r) order by r.nombre)) from public.recursos r where r.organizacion_id = p_org
$$;

create or replace function api.sp_recurso_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v jsonb;
begin
  if p_id is null then
    insert into public.recursos (organizacion_id, sucursal_id, nombre, categoria, cantidad, notas)
    values (p_org, (p_datos->>'sucursal_id')::uuid, p_datos->>'nombre', coalesce(p_datos->>'categoria', 'otro'),
            coalesce((p_datos->>'cantidad')::int, 1), nullif(p_datos->>'notas', ''))
    returning to_jsonb(recursos.*) into v;
  else
    update public.recursos set sucursal_id = (p_datos->>'sucursal_id')::uuid, nombre = p_datos->>'nombre',
           categoria = coalesce(p_datos->>'categoria', categoria), cantidad = coalesce((p_datos->>'cantidad')::int, cantidad),
           notas = nullif(p_datos->>'notas', '')
     where id = p_id and organizacion_id = p_org returning to_jsonb(recursos.*) into v;
    if v is null then raise exception 'No se encontró el recurso o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

create or replace function api.sp_feriados_listar(p_org uuid, p_desde date, p_hasta date)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(f) order by f.fecha)) from public.feriados f
   where f.fecha between p_desde and p_hasta and (f.organizacion_id is null or f.organizacion_id = p_org)
$$;

create or replace function api.sp_feriado_crear(p_org uuid, p_fecha date, p_nombre text)
returns jsonb language sql set search_path = '' as $$
  insert into public.feriados (organizacion_id, fecha, nombre) values (p_org, p_fecha, trim(p_nombre)) returning to_jsonb(feriados.*)
$$;

-- -----------------------------------------------------------------------------
-- Clientes
-- -----------------------------------------------------------------------------
create or replace function api.sp_clientes_listar(p_org uuid, p_q text default null, p_limite int default 50, p_desplazamiento int default 0)
returns jsonb language sql stable set search_path = '' as $$
  with base as (
    select c.* from public.clientes c
     where c.organizacion_id = p_org
       and (coalesce(length(trim(p_q)), 0) < 2 or c.busqueda like '%' || public.normalizar(p_q) || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'filas', (select api.lista(jsonb_agg(to_jsonb(b) order by b.nombre)) from (select * from base order by nombre limit least(p_limite, 10000) offset p_desplazamiento) b))
$$;

create or replace function api.sp_clientes_buscar(p_org uuid, p_q text, p_limite int default 6)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'email', c.email) order by c.nombre))
    from (select * from public.clientes c where c.organizacion_id = p_org and c.busqueda like '%' || public.normalizar(p_q) || '%'
          order by c.nombre limit p_limite) c
$$;

create or replace function api.sp_cliente_obtener(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v jsonb;
begin
  select to_jsonb(c) into v from public.clientes c where c.id = p_id;
  if v is null then raise exception 'No se encontró el cliente o no tenés acceso.' using errcode = 'P0002'; end if;
  return v || jsonb_build_object(
    'reservas', (select api.lista(jsonb_agg(to_jsonb(r) order by r.inicio desc)) from public.reservas r where r.cliente_id = p_id),
    'presupuestos', (select api.lista(jsonb_agg(jsonb_build_object('id', p.id, 'numero', p.numero, 'titulo', p.titulo, 'estado', p.estado,
                       'total', p.total, 'creado_at', p.creado_at) order by p.creado_at desc)) from public.presupuestos p where p.cliente_id = p_id));
end $$;

create or replace function api.sp_cliente_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare v public.clientes;
begin
  if p_id is null then
    insert into public.clientes (organizacion_id, tipo, nombre, documento, email, telefono, direccion, origen, notas)
    values (p_org, coalesce(p_datos->>'tipo', 'persona'), trim(p_datos->>'nombre'), nullif(trim(coalesce(p_datos->>'documento', '')), ''),
            nullif(lower(trim(coalesce(p_datos->>'email', ''))), ''), nullif(trim(coalesce(p_datos->>'telefono', '')), ''),
            nullif(trim(coalesce(p_datos->>'direccion', '')), ''), nullif(p_datos->>'origen', ''), nullif(trim(coalesce(p_datos->>'notas', '')), ''))
    returning * into v;
  else
    update public.clientes set tipo = coalesce(p_datos->>'tipo', tipo), nombre = trim(p_datos->>'nombre'),
           documento = nullif(trim(coalesce(p_datos->>'documento', '')), ''), email = nullif(lower(trim(coalesce(p_datos->>'email', ''))), ''),
           telefono = nullif(trim(coalesce(p_datos->>'telefono', '')), ''), direccion = nullif(trim(coalesce(p_datos->>'direccion', '')), ''),
           origen = nullif(p_datos->>'origen', ''), notas = nullif(trim(coalesce(p_datos->>'notas', '')), '')
     where id = p_id and organizacion_id = p_org returning * into v;
    if v.id is null then raise exception 'No se encontró el cliente o no tenés permiso.' using errcode = '42501'; end if;
  end if;
  return jsonb_build_object('id', v.id, 'nombre', v.nombre, 'telefono', v.telefono, 'email', v.email);
end $$;

-- -----------------------------------------------------------------------------
-- Eventos (reservas)
-- -----------------------------------------------------------------------------
create or replace function api.sp_reservas_listar(p_org uuid, p_filtros jsonb default '{}', p_limite int default 50, p_desplazamiento int default 0)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_estado text := coalesce(p_filtros->>'estado', 'proximas');
  v_contrato text := nullif(p_filtros->>'contrato', '');
  v_texto text := nullif(trim(coalesce(p_filtros->>'texto', '')), '');
  v_numero int := case when nullif(trim(coalesce(p_filtros->>'texto', '')), '') ~ '^#?\d{1,9}$' then ltrim(trim(p_filtros->>'texto'), '#')::int end;
  v_asc boolean := coalesce(p_filtros->>'estado', 'proximas') in ('proximas', 'consulta', 'tentativa');
  v jsonb;
begin
  with base as (
    select r.* from public.reservas r
     where r.organizacion_id = p_org
       and (v_estado = '' or (v_estado = 'proximas' and r.estado in ('consulta','tentativa','senada','confirmada') and r.fin >= now())
            or (v_estado not in ('', 'proximas') and r.estado::text = v_estado))
       and (v_contrato is null
            or (v_contrato = 'pendiente' and r.contrato_estado in ('pendiente','enviado') and r.estado in ('senada','confirmada') and r.fin >= now())
            or (v_contrato <> 'pendiente' and r.contrato_estado::text = v_contrato))
       and (p_filtros->>'desde' is null or r.inicio >= (p_filtros->>'desde')::timestamptz)
       and (p_filtros->>'hasta' is null or r.inicio < (p_filtros->>'hasta')::timestamptz)
       and (p_filtros->>'sucursal' is null or r.sucursal_id = (p_filtros->>'sucursal')::uuid)
       and (v_texto is null or (v_numero is not null and r.numero = v_numero) or (v_numero is null and r.titulo ilike '%' || v_texto || '%'))
  ), pagina as (
    select b.*, row_number() over (order by case when v_asc then b.inicio end asc, case when not v_asc then b.inicio end desc) as orden
      from base b
     order by orden limit least(p_limite, 5000) offset p_desplazamiento
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'filas', (select api.lista(jsonb_agg((to_jsonb(r) - 'orden') || jsonb_build_object(
                 'clientes', (select jsonb_build_object('id', c.id, 'nombre', c.nombre) from public.clientes c where c.id = r.cliente_id),
                 'reserva_espacios', (select api.lista(jsonb_agg(jsonb_build_object('espacios', jsonb_build_object('nombre', e.nombre))))
                                        from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id where re.reserva_id = r.id),
                 'saldo', s.saldo, 'vencido', s.vencido) order by r.orden))
                from pagina r left join public.v_reservas_saldo s on s.reserva_id = r.id))
    into v;
  return v;
end $$;

-- Reserva con cliente, espacios y servicios (formulario y precarga de presupuestos).
create or replace function api.sp_reserva_obtener(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v jsonb;
begin
  select to_jsonb(r) || jsonb_build_object(
           'clientes', (select jsonb_build_object('id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'email', c.email) from public.clientes c where c.id = r.cliente_id),
           'sucursales', (select jsonb_build_object('nombre', s.nombre) from public.sucursales s where s.id = r.sucursal_id),
           'reserva_espacios', (select api.lista(jsonb_agg(jsonb_build_object('espacio_id', re.espacio_id, 'antes_min', re.antes_min, 'despues_min', re.despues_min,
                                  'espacios', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'color', e.color, 'capacidad_maxima', e.capacidad_maxima,
                                                                 'capacidad_minima', e.capacidad_minima))))
                                  from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id where re.reserva_id = r.id),
           'reserva_items', (select api.lista(jsonb_agg(to_jsonb(i) order by i.orden)) from public.reserva_items i where i.reserva_id = r.id))
    into v
    from public.reservas r where r.id = p_id;
  if v is null then raise exception 'No se encontró el evento o no tenés acceso.' using errcode = 'P0002'; end if;
  return v;
end $$;

-- Ficha completa del evento. Lo que el rol no puede ver vuelve vacío (RLS).
create or replace function api.sp_reserva_ficha(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_r jsonb; v_res public.reservas;
begin
  v_r := api.sp_reserva_obtener(p_id);
  select * into v_res from public.reservas where id = p_id;
  return jsonb_build_object(
    'reserva', v_r,
    'responsable', (select jsonb_build_object('nombre', p.nombre, 'email', p.email) from public.perfiles p where p.id = v_res.responsable_id),
    'pagos', (select api.lista(jsonb_agg(to_jsonb(pg) || jsonb_build_object('registrado_por_nombre', pf.nombre) order by pg.fecha, pg.numero_comprobante))
                from public.pagos pg left join public.perfiles pf on pf.id = pg.registrado_por where pg.reserva_id = p_id),
    'cuotas', (select api.lista(jsonb_agg(to_jsonb(c) order by c.vencimiento)) from public.v_cuotas_estado c where c.reserva_id = p_id),
    'saldo', case when public.tiene_permiso(v_res.organizacion_id, 'pagos.ver') then
               (select jsonb_build_object('pagado', s.pagado, 'saldo', s.saldo, 'vencido', s.vencido) from public.v_reservas_saldo s where s.reserva_id = p_id) end,
    'tareas', (select api.lista(jsonb_agg(to_jsonb(t) order by t.vence_el nulls last, t.creado_at)) from public.tareas t where t.reserva_id = p_id),
    'historial', (select api.lista(jsonb_agg(jsonb_build_object('id', a.id, 'accion', a.accion, 'creado_at', a.creado_at, 'cambios', a.cambios) order by a.creado_at desc))
                    from (select * from public.auditoria a where a.organizacion_id = v_res.organizacion_id and a.tabla = 'reservas'
                            and a.registro_id = p_id::text order by a.creado_at desc limit 30) a),
    'garantia', (select to_jsonb(g) || jsonb_build_object('cobrada_por_nombre', pc.nombre, 'devuelta_por_nombre', pd.nombre)
                   from public.garantias g left join public.perfiles pc on pc.id = g.cobrada_por left join public.perfiles pd on pd.id = g.devuelta_por
                  where g.reserva_id = p_id));
end $$;

create or replace function api.sp_reserva_guardar(p_org uuid, p_id uuid, p_datos jsonb, p_espacios jsonb)
returns uuid language sql set search_path = '' as $$ select public.guardar_reserva(p_org, p_id, p_datos, p_espacios) $$;

create or replace function api.sp_reserva_estado(p_id uuid, p_estado text, p_motivo text default null)
returns void language plpgsql set search_path = '' as $$
begin
  update public.reservas set estado = p_estado::public.estado_reserva,
         motivo_cancelacion = case when p_estado = 'cancelada' then nullif(trim(coalesce(p_motivo, '')), '') else motivo_cancelacion end
   where id = p_id;
  if not found then raise exception 'No se encontró el evento o no tenés permiso.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_reserva_contrato(p_id uuid, p_estado text)
returns void language plpgsql set search_path = '' as $$
begin
  update public.reservas set contrato_estado = p_estado::public.estado_contrato where id = p_id;
  if not found then raise exception 'No se encontró el evento o no tenés permiso.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_disponibilidad(p_org uuid, p_espacios uuid[], p_inicio timestamptz, p_fin timestamptz, p_excluir uuid default null, p_invitados int default null)
returns jsonb language sql stable set search_path = '' as $$
  select public.verificar_disponibilidad(p_org, p_espacios, p_inicio, p_fin, p_excluir, p_invitados)
$$;

create or replace function api.sp_reserva_item_agregar(p_reserva uuid, p_datos jsonb)
returns uuid language sql set search_path = '' as $$
  select public.agregar_item_reserva(p_reserva, p_datos->>'descripcion', (p_datos->>'cantidad')::numeric, p_datos->>'unidad', (p_datos->>'precio')::numeric,
    nullif(p_datos->>'servicio_id', '')::uuid, coalesce((p_datos->>'es_adicional')::boolean, true), coalesce((p_datos->>'crear_cuota')::boolean, false),
    nullif(p_datos->>'vencimiento', '')::date)
$$;

-- Agenda del calendario: reservas, bloqueos, feriados y entrevistas del rango.
create or replace function api.sp_agenda(p_org uuid, p_inicio timestamptz, p_fin timestamptz, p_desde date, p_hasta date,
                                         p_sucursal uuid default null, p_incluir_canceladas boolean default false)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reservas', (select api.lista(jsonb_agg(jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo, 'estado', r.estado, 'inicio', r.inicio,
                    'fin', r.fin, 'invitados', r.invitados, 'sucursal_id', r.sucursal_id,
                    'clientes', (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = r.cliente_id),
                    'reserva_espacios', (select api.lista(jsonb_agg(jsonb_build_object('espacio_id', re.espacio_id, 'antes_min', re.antes_min, 'despues_min', re.despues_min)))
                                           from public.reserva_espacios re where re.reserva_id = r.id)) order by r.inicio))
                   from public.reservas r
                  where r.organizacion_id = p_org and r.inicio < p_fin and r.fin > p_inicio
                    and (p_sucursal is null or r.sucursal_id = p_sucursal) and (p_incluir_canceladas or r.estado <> 'cancelada')),
    'bloqueos', (select api.lista(jsonb_agg(jsonb_build_object('id', b.id, 'espacio_id', b.espacio_id, 'inicio', b.inicio, 'fin', b.fin, 'tipo', b.tipo, 'motivo', b.motivo)))
                   from public.bloqueos b where b.organizacion_id = p_org and b.inicio < p_fin and b.fin > p_inicio),
    'feriados', (select api.lista(jsonb_agg(jsonb_build_object('id', f.id, 'fecha', f.fecha, 'nombre', f.nombre)))
                   from public.feriados f where f.fecha between p_desde and p_hasta and (f.organizacion_id is null or f.organizacion_id = p_org)),
    'entrevistas', (select api.lista(jsonb_agg(jsonb_build_object('id', e.id, 'inicio', e.inicio, 'duracion_min', e.duracion_min, 'estado', e.estado,
                       'contacto_nombre', e.contacto_nombre, 'modalidad', e.modalidad, 'sucursal_id', e.sucursal_id,
                       'clientes', (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = e.cliente_id))))
                      from public.entrevistas e where e.organizacion_id = p_org and e.inicio >= p_inicio - interval '1 day' and e.inicio < p_fin and e.estado <> 'cancelada'))
$$;

create or replace function api.sp_bloqueos_crear(p_org uuid, p_espacios uuid[], p_inicio timestamptz, p_fin timestamptz, p_tipo text, p_motivo text)
returns void language sql set search_path = '' as $$
  insert into public.bloqueos (organizacion_id, espacio_id, inicio, fin, tipo, motivo)
  select p_org, e, p_inicio, p_fin, p_tipo, nullif(trim(coalesce(p_motivo, '')), '') from unnest(p_espacios) e
$$;

-- -----------------------------------------------------------------------------
-- Cobros, cuotas y comprobantes
-- -----------------------------------------------------------------------------
create or replace function api.sp_pago_registrar(p_reserva uuid, p_datos jsonb)
returns uuid language sql set search_path = '' as $$
  select public.registrar_pago(p_reserva, (p_datos->>'monto')::numeric, (p_datos->>'fecha')::date, p_datos->>'medio', p_datos->>'concepto',
                               nullif(p_datos->>'referencia', ''), nullif(p_datos->>'notas', ''))
$$;

create or replace function api.sp_pago_anular(p_id uuid, p_motivo text)
returns void language plpgsql set search_path = '' as $$
begin
  update public.pagos set anulado = true, anulado_motivo = p_motivo where id = p_id;
  if not found then raise exception 'No se encontró el cobro o no tenés permiso para anularlo.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_cuota_crear(p_org uuid, p_reserva uuid, p_concepto text, p_vencimiento date, p_monto numeric)
returns void language sql set search_path = '' as $$
  insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto)
  values (p_org, p_reserva, coalesce(nullif(trim(coalesce(p_concepto, '')), ''), 'Cuota'), p_vencimiento, p_monto)
$$;

-- Reemplaza el plan de cuotas completo (en una transacción).
create or replace function api.sp_cuotas_reemplazar(p_org uuid, p_reserva uuid, p_cuotas jsonb)
returns void language sql set search_path = '' as $$
  delete from public.cuotas where reserva_id = p_reserva;
  insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto)
  select p_org, p_reserva, c->>'concepto', (c->>'vencimiento')::date, (c->>'monto')::numeric
    from jsonb_array_elements(coalesce(p_cuotas, '[]')) c where (c->>'monto')::numeric > 0;
$$;

create or replace function api.sp_cobros_listar(p_org uuid, p_desde date, p_hasta date)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', p.id, 'numero_comprobante', p.numero_comprobante, 'fecha', p.fecha, 'monto', p.monto, 'medio', p.medio,
           'concepto', p.concepto, 'referencia', p.referencia, 'anulado', p.anulado,
           'reservas', jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo)) order by p.fecha desc, p.numero_comprobante desc))
    from (select * from public.pagos p where p.organizacion_id = p_org and p.fecha between p_desde and p_hasta order by p.fecha desc limit 1000) p
    join public.reservas r on r.id = p.reserva_id
$$;

-- p_vista: 'vencidos' (antes de hoy) o 'proximos' (de hoy a 60 días).
create or replace function api.sp_cuotas_pendientes(p_org uuid, p_vista text, p_hoy date)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', c.id, 'reserva_id', c.reserva_id, 'concepto', c.concepto, 'vencimiento', c.vencimiento,
           'pendiente', c.pendiente, 'numero', r.numero, 'titulo', r.titulo) order by c.vencimiento))
    from public.v_cuotas_estado c join public.reservas r on r.id = c.reserva_id
   where c.organizacion_id = p_org and c.pendiente > 0 and r.estado <> 'cancelada'
     and case when p_vista = 'vencidos' then c.vencimiento < p_hoy else c.vencimiento between p_hoy and p_hoy + 60 end
$$;

create or replace function api.sp_comprobante(p_pago uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v jsonb;
begin
  select to_jsonb(p) || jsonb_build_object(
           'reservas', jsonb_build_object('numero', r.numero, 'titulo', r.titulo, 'inicio', r.inicio, 'precio_total', r.precio_total,
                                          'clientes', (select jsonb_build_object('nombre', c.nombre, 'telefono', c.telefono) from public.clientes c where c.id = r.cliente_id)),
           'pagado_hasta_este', (select coalesce(sum(x.monto), 0) from public.pagos x
                                  where x.reserva_id = p.reserva_id and not x.anulado and x.numero_comprobante <= p.numero_comprobante),
           'registrado_por_nombre', (select pf.nombre from public.perfiles pf where pf.id = p.registrado_por))
    into v
    from public.pagos p join public.reservas r on r.id = p.reserva_id where p.id = p_pago;
  if v is null then raise exception 'No se encontró el cobro o no tenés acceso.' using errcode = 'P0002'; end if;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- Garantías
-- -----------------------------------------------------------------------------
create or replace function api.sp_garantias_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(g) || jsonb_build_object('reservas', jsonb_build_object('id', r.id, 'numero', r.numero, 'titulo', r.titulo,
           'inicio', r.inicio, 'fin', r.fin, 'clientes', (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = r.cliente_id)))
           order by g.creado_at desc))
    from public.garantias g join public.reservas r on r.id = g.reserva_id where g.organizacion_id = p_org
$$;
create or replace function api.sp_garantia_pedir(p_reserva uuid, p_monto numeric)
returns uuid language sql set search_path = '' as $$ select public.pedir_garantia(p_reserva, p_monto) $$;
create or replace function api.sp_garantia_quitar(p_reserva uuid)
returns void language sql set search_path = '' as $$ select public.quitar_garantia(p_reserva) $$;
create or replace function api.sp_garantia_cobrar(p_reserva uuid, p_fecha date, p_medio text, p_referencia text default null)
returns int language sql set search_path = '' as $$ select public.cobrar_garantia(p_reserva, p_fecha, p_medio, p_referencia) $$;
create or replace function api.sp_garantia_devolver(p_reserva uuid, p_fecha date, p_monto_devuelto numeric, p_medio text, p_motivo text default null)
returns int language sql set search_path = '' as $$ select public.devolver_garantia(p_reserva, p_fecha, p_monto_devuelto, p_medio, p_motivo) $$;

-- -----------------------------------------------------------------------------
-- Gastos y tareas
-- -----------------------------------------------------------------------------
create or replace function api.sp_gastos_listar(p_org uuid, p_desde date, p_hasta date, p_categoria text default null)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(g) order by g.fecha desc, g.creado_at desc))
    from (select * from public.gastos g where g.organizacion_id = p_org and g.fecha between p_desde and p_hasta
            and (p_categoria is null or p_categoria = '' or g.categoria = p_categoria) order by g.fecha desc limit 1000) g
$$;

create or replace function api.sp_gasto_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if p_id is null then
    insert into public.gastos (organizacion_id, sucursal_id, reserva_id, fecha, categoria, descripcion, proveedor, monto, medio)
    values (p_org, nullif(p_datos->>'sucursal_id', '')::uuid, nullif(p_datos->>'reserva_id', '')::uuid, (p_datos->>'fecha')::date,
            coalesce(p_datos->>'categoria', 'otro'), trim(p_datos->>'descripcion'), nullif(trim(coalesce(p_datos->>'proveedor', '')), ''),
            (p_datos->>'monto')::numeric, coalesce(p_datos->>'medio', 'efectivo'));
  else
    update public.gastos set sucursal_id = nullif(p_datos->>'sucursal_id', '')::uuid, fecha = (p_datos->>'fecha')::date,
           categoria = coalesce(p_datos->>'categoria', categoria), descripcion = trim(p_datos->>'descripcion'),
           proveedor = nullif(trim(coalesce(p_datos->>'proveedor', '')), ''), monto = (p_datos->>'monto')::numeric, medio = coalesce(p_datos->>'medio', medio)
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró el gasto o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;

-- p_quien: 'mias' | 'todas' | 'sin'; p_estado: 'abiertas' | 'hechas'
create or replace function api.sp_tareas_listar(p_org uuid, p_quien text, p_estado text)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(t) || jsonb_build_object('reservas',
           (select jsonb_build_object('numero', r.numero, 'titulo', r.titulo) from public.reservas r where r.id = t.reserva_id))
           order by t.vence_el nulls last, t.creado_at))
    from (select * from public.tareas t where t.organizacion_id = p_org
            and (p_quien <> 'mias' or t.asignada_a = auth.uid()) and (p_quien <> 'sin' or t.asignada_a is null)
            and case when p_estado = 'hechas' then t.estado = 'hecha' else t.estado <> 'hecha' end
          order by t.vence_el nulls last limit 500) t
$$;

create or replace function api.sp_tarea_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if p_id is null then
    insert into public.tareas (organizacion_id, reserva_id, titulo, descripcion, vence_el, asignada_a, prioridad)
    values (p_org, nullif(p_datos->>'reserva_id', '')::uuid, trim(p_datos->>'titulo'), nullif(trim(coalesce(p_datos->>'descripcion', '')), ''),
            nullif(p_datos->>'vence_el', '')::date, nullif(p_datos->>'asignada_a', '')::uuid, coalesce(p_datos->>'prioridad', 'media'));
  else
    update public.tareas set titulo = trim(p_datos->>'titulo'), descripcion = nullif(trim(coalesce(p_datos->>'descripcion', '')), ''),
           vence_el = nullif(p_datos->>'vence_el', '')::date, asignada_a = nullif(p_datos->>'asignada_a', '')::uuid,
           prioridad = coalesce(p_datos->>'prioridad', prioridad)
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró la tarea o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;

create or replace function api.sp_tarea_estado(p_id uuid, p_estado text)
returns void language plpgsql set search_path = '' as $$
begin
  update public.tareas set estado = p_estado where id = p_id;
  if not found then raise exception 'No se encontró la tarea o no tenés permiso.' using errcode = '42501'; end if;
end $$;

-- -----------------------------------------------------------------------------
-- Catálogo y presupuestos
-- -----------------------------------------------------------------------------
create or replace function api.sp_servicios_listar(p_org uuid, p_solo_activos boolean default false)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(s) order by s.tipo, s.nombre)) from public.servicios s
   where s.organizacion_id = p_org and (not p_solo_activos or s.activo)
$$;

create or replace function api.sp_servicio_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if p_id is null then
    insert into public.servicios (organizacion_id, nombre, descripcion, tipo, categoria, unidad, precio, costo)
    values (p_org, trim(p_datos->>'nombre'), nullif(trim(coalesce(p_datos->>'descripcion', '')), ''), coalesce(p_datos->>'tipo', 'servicio'),
            coalesce(p_datos->>'categoria', 'otro'), coalesce(p_datos->>'unidad', 'evento'), (p_datos->>'precio')::numeric, nullif(p_datos->>'costo', '')::numeric);
  else
    update public.servicios set nombre = trim(p_datos->>'nombre'), descripcion = nullif(trim(coalesce(p_datos->>'descripcion', '')), ''),
           tipo = coalesce(p_datos->>'tipo', tipo), categoria = coalesce(p_datos->>'categoria', categoria), unidad = coalesce(p_datos->>'unidad', unidad),
           precio = (p_datos->>'precio')::numeric, costo = nullif(p_datos->>'costo', '')::numeric
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró el servicio o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;

-- p_estado: 'abiertos' (borrador y enviados), '' (todos) o un estado puntual
create or replace function api.sp_presupuestos_listar(p_org uuid, p_estado text default 'abiertos', p_texto text default null)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', p.id, 'numero', p.numero, 'titulo', p.titulo, 'estado', p.estado, 'total', p.total,
           'valido_hasta', p.valido_hasta, 'fecha_evento', p.fecha_evento, 'creado_at', p.creado_at,
           'clientes', (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = p.cliente_id)) order by p.creado_at desc))
    from (select * from public.presupuestos p where p.organizacion_id = p_org
            and case when p_estado = 'abiertos' then p.estado in ('borrador','enviado') when coalesce(p_estado, '') = '' then true else p.estado = p_estado end
            and (coalesce(trim(p_texto), '') = ''
                 or (trim(p_texto) ~ '^#?\d{1,9}$' and p.numero = ltrim(trim(p_texto), '#')::int)
                 or (trim(p_texto) !~ '^#?\d{1,9}$' and p.titulo ilike '%' || trim(p_texto) || '%'))
          order by p.creado_at desc limit 300) p
$$;

create or replace function api.sp_presupuesto_obtener(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v jsonb;
begin
  select to_jsonb(p) || jsonb_build_object(
           'clientes', (select jsonb_build_object('id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'email', c.email) from public.clientes c where c.id = p.cliente_id),
           'presupuesto_items', (select api.lista(jsonb_agg(to_jsonb(i) order by i.orden)) from public.presupuesto_items i where i.presupuesto_id = p.id))
    into v from public.presupuestos p where p.id = p_id;
  if v is null then raise exception 'No se encontró el presupuesto o no tenés acceso.' using errcode = 'P0002'; end if;
  return v;
end $$;

create or replace function api.sp_presupuesto_guardar(p_org uuid, p_id uuid, p_datos jsonb, p_items jsonb)
returns uuid language sql set search_path = '' as $$ select public.guardar_presupuesto(p_org, p_id, p_datos, p_items) $$;
create or replace function api.sp_presupuesto_aceptar(p_id uuid, p_estado text)
returns uuid language sql set search_path = '' as $$ select public.aceptar_presupuesto(p_id, p_estado) $$;

-- -----------------------------------------------------------------------------
-- Entrevistas
-- -----------------------------------------------------------------------------
create or replace function api.sp_entrevistas_listar(p_org uuid, p_desde timestamptz, p_hasta timestamptz, p_estado text default null)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(e) || jsonb_build_object('clientes',
           (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = e.cliente_id)) order by e.inicio))
    from public.entrevistas e
   where e.organizacion_id = p_org and e.inicio >= p_desde and e.inicio < p_hasta and (p_estado is null or e.estado = p_estado)
$$;

create or replace function api.sp_entrevista_obtener(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v jsonb;
begin
  select to_jsonb(e) || jsonb_build_object('clientes',
           (select jsonb_build_object('id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'email', c.email) from public.clientes c where c.id = e.cliente_id))
    into v from public.entrevistas e where e.id = p_id;
  if v is null then raise exception 'No se encontró la entrevista o no tenés acceso.' using errcode = 'P0002'; end if;
  return v;
end $$;

create or replace function api.sp_entrevista_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  if p_id is null then
    insert into public.entrevistas (organizacion_id, cliente_id, contacto_nombre, contacto_telefono, inicio, duracion_min, modalidad, sucursal_id,
                                    enlace, motivo, asignada_a, estado, notas)
    values (p_org, nullif(p_datos->>'cliente_id', '')::uuid, nullif(p_datos->>'contacto_nombre', ''), nullif(p_datos->>'contacto_telefono', ''),
            (p_datos->>'inicio')::timestamptz, coalesce((p_datos->>'duracion_min')::int, 45), coalesce(p_datos->>'modalidad', 'presencial'),
            nullif(p_datos->>'sucursal_id', '')::uuid, nullif(p_datos->>'enlace', ''), nullif(p_datos->>'motivo', ''),
            nullif(p_datos->>'asignada_a', '')::uuid, coalesce(p_datos->>'estado', 'programada'), nullif(p_datos->>'notas', ''));
  else
    update public.entrevistas set cliente_id = nullif(p_datos->>'cliente_id', '')::uuid, contacto_nombre = nullif(p_datos->>'contacto_nombre', ''),
           contacto_telefono = nullif(p_datos->>'contacto_telefono', ''), inicio = (p_datos->>'inicio')::timestamptz,
           duracion_min = coalesce((p_datos->>'duracion_min')::int, duracion_min), modalidad = coalesce(p_datos->>'modalidad', modalidad),
           sucursal_id = nullif(p_datos->>'sucursal_id', '')::uuid, enlace = nullif(p_datos->>'enlace', ''), motivo = nullif(p_datos->>'motivo', ''),
           asignada_a = nullif(p_datos->>'asignada_a', '')::uuid, estado = coalesce(p_datos->>'estado', estado), notas = nullif(p_datos->>'notas', '')
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró la entrevista o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Usuarios, invitaciones, roles y auditoría
-- -----------------------------------------------------------------------------
create or replace function api.sp_roles_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(r) order by r.creado_at)) from public.roles r where r.organizacion_id = p_org
$$;

create or replace function api.sp_invitaciones_listar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(i) || jsonb_build_object('roles', jsonb_build_object('nombre', r.nombre)) order by i.creado_at desc))
    from public.invitaciones i join public.roles r on r.id = i.rol_id
   where i.organizacion_id = p_org and i.aceptada_at is null and not i.revocada
$$;

create or replace function api.sp_invitacion_crear(p_org uuid, p_email text, p_rol uuid)
returns text language sql set search_path = '' as $$
  insert into public.invitaciones (organizacion_id, email, rol_id, creada_por)
  values (p_org, lower(trim(p_email)), p_rol, auth.uid()) returning token
$$;

create or replace function api.sp_invitacion_revocar(p_id uuid)
returns void language plpgsql set search_path = '' as $$
begin
  update public.invitaciones set revocada = true where id = p_id;
  if not found then raise exception 'No se encontró la invitación o no tenés permiso.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_invitacion_ver(p_token text)
returns jsonb language sql stable set search_path = '' as $$ select public.ver_invitacion(p_token) $$;
create or replace function api.sp_invitacion_aceptar(p_token text)
returns uuid language sql set search_path = '' as $$ select public.aceptar_invitacion(p_token) $$;

create or replace function api.sp_membresia_actualizar(p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  update public.membresias m set
    rol_id = case when p_datos ? 'rol_id' then (p_datos->>'rol_id')::uuid else m.rol_id end,
    activo = case when p_datos ? 'activo' then (p_datos->>'activo')::boolean else m.activo end
   where m.id = p_id;
  if not found then raise exception 'No se encontró el usuario o no tenés permiso.' using errcode = '42501'; end if;
end $$;

create or replace function api.sp_roles_matriz(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'roles', api.sp_roles_listar(p_org),
    'permisos', (select api.lista(jsonb_agg(to_jsonb(p) order by p.orden)) from public.permisos p),
    'asignados', (select api.lista(jsonb_agg(jsonb_build_object('rol_id', rp.rol_id, 'permiso', rp.permiso))) from public.rol_permisos rp where rp.organizacion_id = p_org))
$$;

create or replace function api.sp_rol_permiso(p_org uuid, p_rol uuid, p_permiso text, p_asignar boolean)
returns void language plpgsql set search_path = '' as $$
begin
  if p_asignar then
    insert into public.rol_permisos (organizacion_id, rol_id, permiso) values (p_org, p_rol, p_permiso) on conflict do nothing;
  else
    delete from public.rol_permisos where rol_id = p_rol and permiso = p_permiso and organizacion_id = p_org;
  end if;
end $$;

create or replace function api.sp_auditoria_listar(p_org uuid, p_tabla text default null, p_accion text default null, p_limite int default 51, p_desplazamiento int default 0)
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(a) order by a.creado_at desc))
    from (select * from public.auditoria a where a.organizacion_id = p_org
            and (coalesce(p_tabla, '') = '' or a.tabla = p_tabla) and (coalesce(p_accion, '') = '' or a.accion = p_accion)
          order by a.creado_at desc limit least(p_limite, 500) offset p_desplazamiento) a
$$;

-- -----------------------------------------------------------------------------
-- Notificaciones y dispositivos
-- -----------------------------------------------------------------------------
create or replace function api.sp_notificaciones_listar()
returns jsonb language sql stable set search_path = '' as $$
  select api.lista(jsonb_agg(to_jsonb(n) order by n.creado_at desc))
    from (select * from public.notificaciones n where n.usuario_id = auth.uid() order by n.creado_at desc limit 30) n
$$;
create or replace function api.sp_notificacion_leer(p_id bigint default null)
returns void language sql set search_path = '' as $$
  update public.notificaciones set leida_at = now() where usuario_id = auth.uid() and leida_at is null and (p_id is null or id = p_id)
$$;
create or replace function api.sp_dispositivo_registrar(p_token text, p_plataforma text)
returns void language sql set search_path = '' as $$ select public.registrar_dispositivo(p_token, p_plataforma) $$;
create or replace function api.sp_dispositivo_quitar(p_token text)
returns void language sql set search_path = '' as $$ select public.quitar_dispositivo(p_token) $$;

-- -----------------------------------------------------------------------------
-- Importación y exportación completa
-- -----------------------------------------------------------------------------
create or replace function api.sp_importar_clientes(p_org uuid, p_filas jsonb)
returns jsonb language sql set search_path = '' as $$ select public.importar_clientes(p_org, p_filas) $$;
create or replace function api.sp_importar_reservas(p_org uuid, p_filas jsonb)
returns jsonb language sql set search_path = '' as $$ select public.importar_reservas(p_org, p_filas) $$;

-- Cada sección vuelve null si el rol no tiene permiso para verla.
create or replace function api.sp_exportar(p_org uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'espacios', (select api.lista(jsonb_agg(to_jsonb(e) || jsonb_build_object('sucursales', jsonb_build_object('nombre', s.nombre)) order by e.nombre))
                   from public.espacios e join public.sucursales s on s.id = e.sucursal_id where e.organizacion_id = p_org),
    'horarios', (select api.lista(jsonb_agg(to_jsonb(h))) from public.espacio_horarios h where h.organizacion_id = p_org),
    'recursos', (select api.lista(jsonb_agg(to_jsonb(r) || jsonb_build_object('sucursales', jsonb_build_object('nombre', s.nombre)) order by r.nombre))
                   from public.recursos r join public.sucursales s on s.id = r.sucursal_id where r.organizacion_id = p_org),
    'clientes', case when public.tiene_permiso(p_org, 'clientes.ver') then
                  (select api.lista(jsonb_agg(to_jsonb(c) order by c.nombre)) from public.clientes c where c.organizacion_id = p_org) end,
    'reservas', case when public.tiene_permiso(p_org, 'reservas.ver') then
                  (select api.lista(jsonb_agg(to_jsonb(r) || jsonb_build_object(
                      'clientes', (select jsonb_build_object('nombre', c.nombre) from public.clientes c where c.id = r.cliente_id),
                      'reserva_espacios', (select api.lista(jsonb_agg(jsonb_build_object('espacios', jsonb_build_object('nombre', e.nombre))))
                                             from public.reserva_espacios re join public.espacios e on e.id = re.espacio_id where re.reserva_id = r.id))
                    order by r.inicio)) from public.reservas r where r.organizacion_id = p_org) end,
    'cuotas', case when public.tiene_permiso(p_org, 'pagos.ver') then
                (select api.lista(jsonb_agg(to_jsonb(c) || jsonb_build_object('reservas', jsonb_build_object('numero', r.numero, 'titulo', r.titulo)) order by c.vencimiento))
                   from public.cuotas c join public.reservas r on r.id = c.reserva_id where c.organizacion_id = p_org) end,
    'pagos', case when public.tiene_permiso(p_org, 'pagos.ver') then
               (select api.lista(jsonb_agg(to_jsonb(p) || jsonb_build_object('reservas', jsonb_build_object('numero', r.numero, 'titulo', r.titulo)) order by p.fecha))
                  from public.pagos p join public.reservas r on r.id = p.reserva_id where p.organizacion_id = p_org) end,
    'gastos', case when public.tiene_permiso(p_org, 'gastos.ver') then
                (select api.lista(jsonb_agg(to_jsonb(g) order by g.fecha)) from public.gastos g where g.organizacion_id = p_org) end,
    'tareas', case when public.tiene_permiso(p_org, 'tareas.ver') then
                (select api.lista(jsonb_agg(to_jsonb(t) || jsonb_build_object('reservas',
                    (select jsonb_build_object('numero', r.numero, 'titulo', r.titulo) from public.reservas r where r.id = t.reserva_id)) order by t.creado_at))
                   from public.tareas t where t.organizacion_id = p_org) end,
    'bloqueos', case when public.tiene_permiso(p_org, 'calendario.ver') then
                  (select api.lista(jsonb_agg(to_jsonb(b) || jsonb_build_object('espacios', jsonb_build_object('nombre', e.nombre)) order by b.inicio))
                     from public.bloqueos b join public.espacios e on e.id = b.espacio_id where b.organizacion_id = p_org) end)
$$;

-- -----------------------------------------------------------------------------
-- Push: los envía la API Node (tarea programada) con rol service_role.
-- -----------------------------------------------------------------------------
create or replace function api.sp_push_pendientes(p_limite int default 200)
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object('id', n.id, 'titulo', n.titulo, 'cuerpo', n.cuerpo, 'url', n.url,
           'tokens', (select api.lista(jsonb_agg(d.token)) from public.dispositivos d where d.usuario_id = n.usuario_id and d.plataforma <> 'web'))))
    from (select * from public.notificaciones n where n.push_enviada_at is null and n.creado_at > now() - interval '2 days'
          order by n.creado_at limit p_limite) n
$$;
create or replace function api.sp_push_marcar(p_ids bigint[], p_tokens_invalidos text[] default '{}')
returns void language sql security definer set search_path = '' as $$
  update public.notificaciones set push_enviada_at = now() where id = any (p_ids);
  delete from public.dispositivos where token = any (p_tokens_invalidos);
$$;

-- El envío de push pasó a la API Node: se quita el disparo por pg_net.
do $$ begin perform cron.unschedule('festy_push'); exception when others then null; end $$;

-- -----------------------------------------------------------------------------
-- Privilegios del esquema api
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema api from public, anon;
grant execute on all functions in schema api to authenticated;
revoke execute on function api.sp_push_pendientes(int), api.sp_push_marcar(bigint[], text[]) from authenticated;
grant execute on function api.sp_push_pendientes(int), api.sp_push_marcar(bigint[], text[]) to service_role;
grant execute on function api.sp_invitacion_ver(text), api.lista(jsonb) to anon;
