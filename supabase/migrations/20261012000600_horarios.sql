-- =============================================================================
-- Festy · Migración 6: guardado atómico de horarios de un espacio.
-- =============================================================================
create or replace function public.guardar_horarios(p_espacio uuid, p_horarios jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_org uuid;
begin
  select organizacion_id into v_org from public.espacios where id = p_espacio;
  if v_org is null then
    raise exception 'El espacio no existe.' using errcode = 'P0002';
  end if;
  delete from public.espacio_horarios where espacio_id = p_espacio;
  insert into public.espacio_horarios (organizacion_id, espacio_id, dia_semana, hora_desde, hora_hasta)
  select v_org, p_espacio, (h->>'dia_semana')::smallint, (h->>'hora_desde')::time, (h->>'hora_hasta')::time
    from jsonb_array_elements(coalesce(p_horarios, '[]'::jsonb)) h;
end $$;
grant execute on function public.guardar_horarios(uuid, jsonb) to authenticated;
