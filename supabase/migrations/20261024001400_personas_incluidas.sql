-- =============================================================================
-- Festy · Migración 14: servicios con personas incluidas
--   Un servicio "por evento" puede incluir hasta N personas y cobrar cada persona
--   extra aparte (ej.: salón hasta 20 personas $350.000, cada persona extra $10.000).
-- =============================================================================

alter table public.servicios
  add column personas_incluidas   int check (personas_incluidas is null or personas_incluidas > 0),
  add column precio_persona_extra numeric(14,2) check (precio_persona_extra is null or precio_persona_extra >= 0),
  add constraint servicios_personas_incluidas_chk check (
    (personas_incluidas is null) = (precio_persona_extra is null) and (personas_incluidas is null or unidad = 'evento'));

create or replace function api.sp_servicio_guardar(p_org uuid, p_id uuid, p_datos jsonb)
returns void language plpgsql set search_path = '' as $$
declare
  v_incluidas int := nullif(p_datos->>'personas_incluidas', '')::int;
  v_extra numeric := nullif(p_datos->>'precio_persona_extra', '')::numeric;
begin
  if p_id is null then
    insert into public.servicios (organizacion_id, nombre, descripcion, tipo, categoria, unidad, precio, costo, personas_incluidas, precio_persona_extra)
    values (p_org, trim(p_datos->>'nombre'), nullif(trim(coalesce(p_datos->>'descripcion', '')), ''), coalesce(p_datos->>'tipo', 'servicio'),
            coalesce(p_datos->>'categoria', 'otro'), coalesce(p_datos->>'unidad', 'evento'), (p_datos->>'precio')::numeric, nullif(p_datos->>'costo', '')::numeric,
            v_incluidas, v_extra);
  else
    update public.servicios set nombre = trim(p_datos->>'nombre'), descripcion = nullif(trim(coalesce(p_datos->>'descripcion', '')), ''),
           tipo = coalesce(p_datos->>'tipo', tipo), categoria = coalesce(p_datos->>'categoria', categoria), unidad = coalesce(p_datos->>'unidad', unidad),
           precio = (p_datos->>'precio')::numeric, costo = nullif(p_datos->>'costo', '')::numeric,
           personas_incluidas = v_incluidas, precio_persona_extra = v_extra
     where id = p_id and organizacion_id = p_org;
    if not found then raise exception 'No se encontró el servicio o no tenés permiso.' using errcode = '42501'; end if;
  end if;
end $$;
