-- =============================================================================
-- Festy · Migración 20: administración de la plataforma.
--
-- El registro público está cerrado: las empresas las da de alta el dueño de
-- Festy desde la API (con la API de administración de GoTrue). Estos SP los usa
-- solo la API con el rol service_role, después de verificar que quien llama es
-- administrador de la plataforma (lista de emails en la configuración del servidor).
-- =============================================================================

-- Todas las empresas con su dueño y su actividad.
create or replace function api.sp_plataforma_empresas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select api.lista(jsonb_agg(jsonb_build_object(
           'id', o.id, 'nombre', o.nombre, 'estado', o.estado, 'creado_at', o.creado_at,
           'duenio', (select jsonb_build_object('nombre', p.nombre, 'email', u.email, 'ultimo_ingreso', u.last_sign_in_at)
                        from public.membresias m join public.roles r on r.id = m.rol_id and r.clave = 'propietario'
                        join auth.users u on u.id = m.usuario_id left join public.perfiles p on p.id = u.id
                       where m.organizacion_id = o.id order by m.creado_at limit 1),
           'usuarios', (select count(*) from public.membresias m where m.organizacion_id = o.id and m.activo),
           'eventos', (select count(*) from public.reservas r where r.organizacion_id = o.id and not r.es_ejemplo),
           'ultimo_evento_cargado', (select max(r.creado_at) from public.reservas r where r.organizacion_id = o.id and not r.es_ejemplo),
           'pagina', case when o.pagina_activa then o.pagina_slug end)
           order by o.creado_at desc))
    from public.organizaciones o
$$;

-- Id de un usuario por email (para no duplicar cuentas al dar de alta una empresa).
create or replace function api.sp_plataforma_usuario_por_email(p_email text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1
$$;

revoke execute on function api.sp_plataforma_empresas(), api.sp_plataforma_usuario_por_email(text) from public, anon, authenticated;
grant execute on function api.sp_plataforma_empresas(), api.sp_plataforma_usuario_por_email(text) to service_role;
