-- =============================================================================
-- Festy · Migración 4: auditoría de operaciones.
-- Un trigger genérico registra altas, cambios (solo los campos modificados) y
-- bajas de las tablas de negocio. El registro es de solo lectura para los
-- usuarios y no tiene FK a organizaciones para conservar la traza.
-- =============================================================================

create table public.auditoria (
  id              bigint generated always as identity primary key,
  organizacion_id uuid not null,
  tabla           text not null,
  registro_id     text,
  accion          text not null check (accion in ('alta','cambio','baja')),
  usuario_id      uuid,
  cambios         jsonb,
  creado_at       timestamptz not null default now()
);
create index auditoria_org_fecha_idx on public.auditoria (organizacion_id, creado_at desc);
create index auditoria_registro_idx on public.auditoria (organizacion_id, tabla, registro_id);

create or replace function public.auditar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  -- el token de invitación es un secreto: nunca se copia a la auditoría
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) - 'token' end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) - 'token' end;
  v_fila jsonb := coalesce(v_new, v_old);
  v_org uuid;
  v_id text;
  v_cambios jsonb;
  k text;
begin
  v_org := case when tg_table_name = 'organizaciones' then (v_fila->>'id')::uuid
                else (v_fila->>'organizacion_id')::uuid end;
  if v_org is null then return null; end if;  -- p. ej. feriados nacionales
  v_id := coalesce(v_fila->>'id', v_fila->>'rol_id');

  if tg_op = 'UPDATE' then
    v_cambios := '{}'::jsonb;
    for k in select jsonb_object_keys(v_new) loop
      if k not in ('actualizado_at', 'busqueda', 'ultimo_numero_reserva') and v_new->k is distinct from v_old->k then
        v_cambios := v_cambios || jsonb_build_object(k, jsonb_build_object('antes', v_old->k, 'despues', v_new->k));
      end if;
    end loop;
    if v_cambios = '{}'::jsonb then return null; end if;
  elsif tg_op = 'INSERT' then
    v_cambios := v_new - 'busqueda';
  else
    v_cambios := v_old - 'busqueda';
  end if;

  insert into public.auditoria (organizacion_id, tabla, registro_id, accion, usuario_id, cambios)
  values (v_org, tg_table_name, v_id,
          case tg_op when 'INSERT' then 'alta' when 'UPDATE' then 'cambio' else 'baja' end,
          auth.uid(), v_cambios);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['organizaciones','membresias','roles','rol_permisos','invitaciones','salones','sucursales',
                           'espacios','espacio_horarios','recursos','feriados','clientes','reservas','reserva_espacios',
                           'bloqueos','cuotas','pagos','gastos','tareas'] loop
    execute format('create trigger %1$s_auditoria after insert or update or delete on public.%1$s
                      for each row execute function public.auditar()', t);
  end loop;
end $$;

alter table public.auditoria enable row level security;
create policy auditoria_lectura on public.auditoria for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'auditoria.ver')));
