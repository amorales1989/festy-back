-- =============================================================================
-- Festy · Migración 12: plan único, sin período de prueba.
--
-- Festy se vende con un solo plan y se cobra por fuera de la app. Toda
-- organización tiene todas las funciones y sin límites de sedes, espacios ni
-- usuarios. Se quitan el período de prueba, el cambio de plan y su permiso.
-- La estructura de planes se conserva (un plan activo) por si se reabre a futuro.
-- =============================================================================

insert into public.planes (clave, nombre, precio_mensual_ars, orden, max_sucursales, max_espacios, max_usuarios, max_reservas_mes, funciones, activo)
values ('festy', 'Festy', 0, 1, null, null, null, null,
        array['calendario','reservas','clientes','cobros','tareas','panel','gastos','importacion','exportacion','auditoria','multi_salon','roles_personalizados'],
        true)
on conflict (clave) do update set nombre = excluded.nombre, max_sucursales = null, max_espacios = null, max_usuarios = null,
  max_reservas_mes = null, funciones = excluded.funciones, activo = true;

alter table public.organizaciones
  alter column plan_clave set default 'festy',
  alter column suscripcion_estado set default 'activa',
  alter column prueba_hasta drop default;

update public.organizaciones set plan_clave = 'festy', suscripcion_estado = 'activa', prueba_hasta = null;

update public.planes set activo = false where clave <> 'festy';

-- Sin cambio de plan: se quitan la función, su SP en la API y el permiso.
drop function if exists api.sp_plan_cambiar(uuid, text);
drop function if exists api.sp_planes_listar();
drop function if exists public.cambiar_plan(uuid, text);
delete from public.permisos where clave = 'plan.gestionar';  -- rol_permisos se borra en cascada
-- Plantillas de roles para las organizaciones nuevas, sin ese permiso.
update public.roles_plantilla set permisos = array_remove(permisos, 'plan.gestionar');
update public.roles_plantilla set descripcion = 'Control total de la cuenta, incluida la baja.' where clave = 'propietario';
update public.roles_plantilla set descripcion = 'Gestiona todo salvo la baja de la cuenta.' where clave = 'administrador';
update public.roles set descripcion = 'Control total de la cuenta, incluida la baja.' where clave = 'propietario';
update public.roles set descripcion = 'Gestiona todo salvo la baja de la cuenta.' where clave = 'administrador';

-- Mensaje de la protección de columnas sensibles (ya no hay sección Plan).
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
    or new.ultimo_numero_garantia is distinct from old.ultimo_numero_garantia) then
    raise exception 'Estos datos de la cuenta no se pueden modificar desde acá.' using errcode = '42501';
  end if;
  return new;
end $$;

do $$ begin
  assert (select count(*) from public.planes where activo) = 1, 'debe quedar un único plan activo';
  assert not exists (select 1 from public.organizaciones where plan_clave <> 'festy' or suscripcion_estado <> 'activa'),
    'todas las organizaciones deben quedar en el plan único y activas';
  assert not exists (select 1 from public.roles_plantilla where 'plan.gestionar' = any (permisos)), 'plantillas sin plan.gestionar';
end $$;
