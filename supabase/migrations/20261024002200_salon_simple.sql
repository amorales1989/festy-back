-- =============================================================================
-- Festy · Migración 22: alta simple de un salón.
--
-- En la interfaz "Salón" es el lugar físico (sucursal, con dirección). La marca
-- (tabla salones) ya no se muestra: se usa la primera de la empresa o se crea
-- una con el nombre de la empresa. Al crear un salón se crea también su espacio
-- principal, así queda listo para reservar; los demás espacios son opcionales.
-- Corre con la identidad del usuario: la RLS exige el permiso sedes.gestionar.
-- =============================================================================

create or replace function api.sp_salon_crear(p_org uuid, p_datos jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_marca uuid;
  v_sucursal uuid;
  v_espacio uuid;
  v_nombre text := trim(coalesce(p_datos->>'nombre', ''));
begin
  if length(v_nombre) < 2 then raise exception 'Ingresá el nombre del salón.' using errcode = '23514'; end if;
  if coalesce((p_datos->>'capacidad_maxima')::int, 0) < 1 then raise exception 'Indicá para cuántas personas es.' using errcode = '23514'; end if;

  select id into v_marca from public.salones where organizacion_id = p_org order by es_ejemplo, creado_at limit 1;
  if v_marca is null then
    insert into public.salones (organizacion_id, nombre)
    select p_org, o.nombre from public.organizaciones o where o.id = p_org
    returning id into v_marca;
    if v_marca is null then raise exception 'No tenés permiso para configurar salones.' using errcode = '42501'; end if;
  end if;

  insert into public.sucursales (organizacion_id, salon_id, nombre, direccion, localidad, provincia, telefono)
  values (p_org, v_marca, v_nombre, nullif(trim(coalesce(p_datos->>'direccion', '')), ''), nullif(trim(coalesce(p_datos->>'localidad', '')), ''),
          nullif(trim(coalesce(p_datos->>'provincia', '')), ''), nullif(trim(coalesce(p_datos->>'telefono', '')), ''))
  returning id into v_sucursal;

  insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima)
  values (p_org, v_sucursal, coalesce(nullif(trim(coalesce(p_datos->>'espacio', '')), ''), v_nombre),
          coalesce(nullif(p_datos->>'tipo', ''), 'salon'), (p_datos->>'capacidad_maxima')::int)
  returning id into v_espacio;
  if jsonb_typeof(p_datos->'horarios') = 'array' then
    perform public.guardar_horarios(v_espacio, p_datos->'horarios');
  end if;

  return jsonb_build_object('sucursal_id', v_sucursal, 'espacio_id', v_espacio);
end $$;

-- Las empresas con un único lugar llamado "Sede principal" (lo creaba el
-- onboarding anterior) pasan a llamarse como la empresa: ahora es "el salón".
update public.sucursales su set nombre = o.nombre
  from public.organizaciones o
 where o.id = su.organizacion_id and su.nombre = 'Sede principal'
   and (select count(*) from public.sucursales x where x.organizacion_id = su.organizacion_id) = 1;

revoke execute on function api.sp_salon_crear(uuid, jsonb) from public, anon;
grant execute on function api.sp_salon_crear(uuid, jsonb) to authenticated;
