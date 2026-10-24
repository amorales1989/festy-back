-- =============================================================================
-- Festy · Migración 8: guardado atómico de presupuesto + ítems.
-- =============================================================================
create or replace function public.guardar_presupuesto(p_org uuid, p_id uuid, p_datos jsonb, p_items jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare v_id uuid := p_id;
begin
  if v_id is null then
    insert into public.presupuestos (organizacion_id, cliente_id, reserva_id, espacio_id, titulo, tipo_evento, fecha_evento, hora_inicio, hora_fin,
                                     invitados, estado, valido_hasta, descuento, sena_porcentaje, cantidad_cuotas, condiciones, notas)
    values (p_org, (p_datos->>'cliente_id')::uuid, nullif(p_datos->>'reserva_id', '')::uuid, nullif(p_datos->>'espacio_id', '')::uuid,
            p_datos->>'titulo', coalesce(p_datos->>'tipo_evento', 'otro'), nullif(p_datos->>'fecha_evento', '')::date,
            nullif(p_datos->>'hora_inicio', '')::time, nullif(p_datos->>'hora_fin', '')::time, nullif(p_datos->>'invitados', '')::int,
            coalesce(p_datos->>'estado', 'borrador'), nullif(p_datos->>'valido_hasta', '')::date, 0,
            coalesce(nullif(p_datos->>'sena_porcentaje', '')::numeric, 30), coalesce(nullif(p_datos->>'cantidad_cuotas', '')::int, 2),
            nullif(p_datos->>'condiciones', ''), nullif(p_datos->>'notas', ''))
    returning id into v_id;
  else
    if exists (select 1 from public.presupuestos where id = v_id and estado = 'aceptado') then
      raise exception 'El presupuesto ya fue aceptado: para cambiarlo, editá el evento.' using errcode = 'P0001';
    end if;
    update public.presupuestos set
      cliente_id = (p_datos->>'cliente_id')::uuid, espacio_id = nullif(p_datos->>'espacio_id', '')::uuid,
      titulo = p_datos->>'titulo', tipo_evento = coalesce(p_datos->>'tipo_evento', 'otro'),
      fecha_evento = nullif(p_datos->>'fecha_evento', '')::date, hora_inicio = nullif(p_datos->>'hora_inicio', '')::time,
      hora_fin = nullif(p_datos->>'hora_fin', '')::time, invitados = nullif(p_datos->>'invitados', '')::int,
      estado = coalesce(p_datos->>'estado', estado), valido_hasta = coalesce(nullif(p_datos->>'valido_hasta', '')::date, valido_hasta),
      descuento = 0, sena_porcentaje = coalesce(nullif(p_datos->>'sena_porcentaje', '')::numeric, 30),
      cantidad_cuotas = coalesce(nullif(p_datos->>'cantidad_cuotas', '')::int, 2),
      condiciones = nullif(p_datos->>'condiciones', ''), notas = nullif(p_datos->>'notas', '')
    where id = v_id and organizacion_id = p_org;
    if not found then
      raise exception 'El presupuesto no existe o no tenés permiso para editarlo.' using errcode = '42501';
    end if;
    delete from public.presupuesto_items where presupuesto_id = v_id;
  end if;

  insert into public.presupuesto_items (organizacion_id, presupuesto_id, servicio_id, descripcion, cantidad, unidad, precio_unitario, orden)
  select p_org, v_id, nullif(i->>'servicio_id', '')::uuid, i->>'descripcion', (i->>'cantidad')::numeric, coalesce(i->>'unidad', 'evento'),
         (i->>'precio_unitario')::numeric, ord::int
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as t(i, ord);

  -- El descuento se aplica al final, cuando el subtotal ya está calculado.
  update public.presupuestos set descuento = least(coalesce(nullif(p_datos->>'descuento', '')::numeric, 0), subtotal) where id = v_id;
  return v_id;
end $$;
grant execute on function public.guardar_presupuesto(uuid, uuid, jsonb, jsonb) to authenticated;
