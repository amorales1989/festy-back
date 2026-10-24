-- =============================================================================
-- Festy · Migración 1: base multiempresa (tenants, perfiles, planes, roles,
-- permisos, membresías e invitaciones).
--
-- Principios:
--   * Cada organización es un tenant. Toda tabla de negocio lleva organizacion_id.
--   * El acceso se decide en la base (RLS + funciones SECURITY DEFINER),
--     nunca solamente en el frontend.
--   * Las funciones SECURITY DEFINER usan search_path vacío y nombres calificados.
-- =============================================================================

create extension if not exists btree_gist with schema extensions;
create extension if not exists pg_trgm   with schema extensions;
create extension if not exists unaccent  with schema extensions;

-- -----------------------------------------------------------------------------
-- Utilidades
-- -----------------------------------------------------------------------------
create or replace function public.tocar_actualizado()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.actualizado_at := now();
  return new;
end $$;

-- Normaliza texto para búsquedas (sin acentos, minúsculas).
create or replace function public.normalizar(t text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, '')))
$$;

-- -----------------------------------------------------------------------------
-- Planes comerciales
-- -----------------------------------------------------------------------------
create table public.planes (
  clave              text primary key,
  nombre             text not null,
  precio_mensual_ars numeric(14,2) not null default 0,
  orden              int not null default 0,
  -- null = ilimitado
  max_sucursales     int,
  max_espacios       int,
  max_usuarios       int,
  max_reservas_mes   int,
  funciones          text[] not null default '{}',
  activo             boolean not null default true
);
comment on table public.planes is 'Catálogo de planes comercializables. Los límites null son ilimitados.';

insert into public.planes (clave, nombre, precio_mensual_ars, orden, max_sucursales, max_espacios, max_usuarios, max_reservas_mes, funciones) values
  ('inicial',     'Inicial',     0, 1, 1,    3,    3,    40,
     array['calendario','reservas','clientes','cobros','tareas','panel']),
  ('profesional', 'Profesional', 0, 2, 3,    15,   15,   null,
     array['calendario','reservas','clientes','cobros','tareas','panel','gastos','importacion','exportacion','auditoria','multi_salon']),
  ('empresa',     'Empresa',     0, 3, null, null, null, null,
     array['calendario','reservas','clientes','cobros','tareas','panel','gastos','importacion','exportacion','auditoria','multi_salon','roles_personalizados']);
-- Los precios quedan en 0 a propósito: se definen comercialmente antes del lanzamiento.

-- -----------------------------------------------------------------------------
-- Organizaciones (tenants)
-- -----------------------------------------------------------------------------
create type public.estado_organizacion as enum ('activa', 'suspendida', 'baja_solicitada');
create type public.estado_suscripcion  as enum ('prueba', 'activa', 'vencida', 'cancelada');

create table public.organizaciones (
  id                        uuid primary key default gen_random_uuid(),
  nombre                    text not null check (length(trim(nombre)) between 2 and 120),
  razon_social              text,
  cuit                      text check (cuit is null or cuit ~ '^\d{2}-?\d{8}-?\d$'),
  email_contacto            text,
  telefono                  text,
  zona_horaria              text not null default 'America/Argentina/Buenos_Aires',
  moneda                    text not null default 'ARS' check (moneda = 'ARS'),
  estado                    public.estado_organizacion not null default 'activa',
  plan_clave                text not null default 'profesional' references public.planes(clave),
  suscripcion_estado        public.estado_suscripcion not null default 'prueba',
  prueba_hasta              date default (current_date + 14),
  -- horas que una reserva tentativa bloquea la fecha antes de vencer
  horas_vencimiento_tentativa int not null default 72 check (horas_vencimiento_tentativa between 1 and 2160),
  onboarding_completado     boolean not null default false,
  baja_solicitada_at        timestamptz,
  creado_por                uuid references auth.users(id) on delete set null,
  creado_at                 timestamptz not null default now(),
  actualizado_at            timestamptz not null default now()
);
create trigger organizaciones_actualizado before update on public.organizaciones
  for each row execute function public.tocar_actualizado();

create or replace function public.validar_zona_horaria()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.zona_horaria is not null
     and not exists (select 1 from pg_catalog.pg_timezone_names where name = new.zona_horaria) then
    raise exception 'La zona horaria "%" no es válida.', new.zona_horaria using errcode = '22023';
  end if;
  return new;
end $$;
create trigger organizaciones_zona_horaria before insert or update of zona_horaria on public.organizaciones
  for each row execute function public.validar_zona_horaria();

-- -----------------------------------------------------------------------------
-- Perfiles de usuario (1:1 con auth.users)
-- -----------------------------------------------------------------------------
create table public.perfiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  nombre              text not null default '',
  email               text not null default '',
  telefono            text,
  organizacion_actual uuid references public.organizaciones(id) on delete set null,
  creado_at           timestamptz not null default now(),
  actualizado_at      timestamptz not null default now()
);
create trigger perfiles_actualizado before update on public.perfiles
  for each row execute function public.tocar_actualizado();

create or replace function public.crear_perfil_usuario()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.perfiles (id, nombre, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', ''), coalesce(new.email, ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger al_crear_usuario after insert on auth.users
  for each row execute function public.crear_perfil_usuario();

create or replace function public.sincronizar_email_perfil()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.perfiles set email = coalesce(new.email, '') where id = new.id;
  return new;
end $$;

create trigger al_cambiar_email_usuario after update of email on auth.users
  for each row execute function public.sincronizar_email_perfil();

-- -----------------------------------------------------------------------------
-- Permisos y roles
-- -----------------------------------------------------------------------------
create table public.permisos (
  clave       text primary key,
  modulo      text not null,
  descripcion text not null,
  orden       int not null default 0
);

insert into public.permisos (clave, modulo, descripcion, orden) values
  ('organizacion.editar',  'Organización', 'Editar datos de la organización y preferencias', 10),
  ('organizacion.eliminar','Organización', 'Solicitar la baja de la cuenta', 11),
  ('plan.gestionar',       'Organización', 'Cambiar plan y suscripción', 12),
  ('usuarios.gestionar',   'Usuarios',     'Invitar, desactivar y cambiar rol de usuarios', 20),
  ('roles.gestionar',      'Usuarios',     'Configurar permisos de cada rol', 21),
  ('auditoria.ver',        'Usuarios',     'Ver el registro de auditoría', 22),
  ('sedes.gestionar',      'Sedes',        'Crear y editar salones, sucursales, espacios, recursos, horarios y feriados', 30),
  ('calendario.ver',       'Calendario',   'Ver el calendario y la disponibilidad', 40),
  ('bloqueos.gestionar',   'Calendario',   'Crear y quitar bloqueos de fechas', 41),
  ('clientes.ver',         'Clientes',     'Ver clientes', 50),
  ('clientes.gestionar',   'Clientes',     'Crear, editar y eliminar clientes', 51),
  ('reservas.ver',         'Reservas',     'Ver reservas y eventos', 60),
  ('reservas.crear',       'Reservas',     'Crear consultas y reservas', 61),
  ('reservas.editar',      'Reservas',     'Editar reservas y cambiar su estado', 62),
  ('reservas.cancelar',    'Reservas',     'Cancelar reservas', 63),
  ('reservas.eliminar',    'Reservas',     'Eliminar reservas definitivamente', 64),
  ('contratos.gestionar',  'Reservas',     'Cambiar el estado del contrato', 65),
  ('pagos.ver',            'Finanzas',     'Ver cobros, saldos e ingresos', 70),
  ('pagos.registrar',      'Finanzas',     'Registrar cobros y planes de pago', 71),
  ('pagos.anular',         'Finanzas',     'Anular cobros registrados', 72),
  ('gastos.ver',           'Finanzas',     'Ver gastos', 73),
  ('gastos.gestionar',     'Finanzas',     'Registrar y editar gastos', 74),
  ('tareas.ver',           'Tareas',       'Ver tareas', 80),
  ('tareas.gestionar',     'Tareas',       'Crear, asignar y editar cualquier tarea', 81),
  ('datos.exportar',       'Datos',        'Exportar datos', 90),
  ('datos.importar',       'Datos',        'Importar clientes y reservas', 91);

create table public.roles (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  clave           text not null,
  nombre          text not null,
  descripcion     text,
  es_sistema      boolean not null default false,
  creado_at       timestamptz not null default now(),
  unique (organizacion_id, clave),
  unique (organizacion_id, id)
);

create table public.rol_permisos (
  organizacion_id uuid not null,
  rol_id          uuid not null,
  permiso         text not null references public.permisos(clave) on delete cascade,
  primary key (rol_id, permiso),
  foreign key (organizacion_id, rol_id) references public.roles(organizacion_id, id) on delete cascade
);

-- Matriz de permisos por defecto de los roles de sistema.
create table public.roles_plantilla (
  clave       text primary key,
  nombre      text not null,
  descripcion text not null,
  orden       int not null,
  permisos    text[] not null
);

insert into public.roles_plantilla (clave, nombre, descripcion, orden, permisos) values
  ('propietario', 'Propietario', 'Control total de la cuenta, incluida la baja y el plan.', 1,
    (select array_agg(clave) from public.permisos)),
  ('administrador', 'Administrador', 'Gestiona todo salvo la baja de la cuenta y el plan.', 2,
    (select array_agg(clave) from public.permisos where clave not in ('organizacion.eliminar','plan.gestionar'))),
  ('recepcion', 'Recepción', 'Atiende consultas, agenda y registra cobros.', 3,
    array['calendario.ver','clientes.ver','clientes.gestionar','reservas.ver','reservas.crear','reservas.editar',
          'pagos.ver','pagos.registrar','tareas.ver']),
  ('vendedor', 'Vendedor', 'Gestiona consultas, presupuestos y cierres.', 4,
    array['calendario.ver','clientes.ver','clientes.gestionar','reservas.ver','reservas.crear','reservas.editar',
          'contratos.gestionar','pagos.ver','tareas.ver']),
  ('finanzas', 'Finanzas', 'Cobros, gastos y reportes.', 5,
    array['calendario.ver','clientes.ver','reservas.ver','contratos.gestionar','pagos.ver','pagos.registrar',
          'pagos.anular','gastos.ver','gastos.gestionar','tareas.ver','datos.exportar']),
  ('coordinador', 'Coordinador', 'Organiza la operación de los eventos.', 6,
    array['calendario.ver','bloqueos.gestionar','clientes.ver','reservas.ver','reservas.editar',
          'tareas.ver','tareas.gestionar']),
  ('operativo', 'Personal operativo', 'Ve la agenda y sus tareas asignadas.', 7,
    array['calendario.ver','reservas.ver','tareas.ver']);

-- -----------------------------------------------------------------------------
-- Membresías e invitaciones
-- -----------------------------------------------------------------------------
create table public.membresias (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  usuario_id      uuid not null references auth.users(id) on delete cascade,
  rol_id          uuid not null,
  activo          boolean not null default true,
  creado_at       timestamptz not null default now(),
  unique (organizacion_id, usuario_id),
  foreign key (organizacion_id, rol_id) references public.roles(organizacion_id, id)
);
create index membresias_usuario_idx on public.membresias (usuario_id) where activo;

create table public.invitaciones (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  email           text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  rol_id          uuid not null,
  token           text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  expira_at       timestamptz not null default now() + interval '7 days',
  aceptada_at     timestamptz,
  aceptada_por    uuid references auth.users(id) on delete set null,
  revocada        boolean not null default false,
  creada_por      uuid references auth.users(id) on delete set null,
  creado_at       timestamptz not null default now(),
  foreign key (organizacion_id, rol_id) references public.roles(organizacion_id, id) on delete cascade
);
create unique index invitaciones_pendiente_unica on public.invitaciones (organizacion_id, lower(email))
  where aceptada_at is null and not revocada;

-- -----------------------------------------------------------------------------
-- Funciones de autorización (usadas por RLS). SECURITY DEFINER para evitar
-- recursión de políticas; solo responden sobre el usuario autenticado.
-- -----------------------------------------------------------------------------
create or replace function public.es_miembro(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.membresias m
    join public.organizaciones o on o.id = m.organizacion_id
    where m.organizacion_id = p_org
      and m.usuario_id = auth.uid()
      and m.activo
      and o.estado <> 'suspendida'
  )
$$;

create or replace function public.tiene_permiso(p_org uuid, p_permiso text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.membresias m
    join public.organizaciones o on o.id = m.organizacion_id
    join public.rol_permisos rp on rp.rol_id = m.rol_id
    where m.organizacion_id = p_org
      and m.usuario_id = auth.uid()
      and m.activo
      and o.estado <> 'suspendida'
      and rp.permiso = p_permiso
  )
$$;

create or replace function public.mis_permisos(p_org uuid)
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(rp.permiso order by rp.permiso), '{}')
  from public.membresias m
  join public.rol_permisos rp on rp.rol_id = m.rol_id
  where m.organizacion_id = p_org and m.usuario_id = auth.uid() and m.activo
$$;

create or replace function public.es_propietario(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.membresias m join public.roles r on r.id = m.rol_id
    where m.organizacion_id = p_org and m.usuario_id = auth.uid() and m.activo and r.clave = 'propietario'
  )
$$;

create or replace function public.org_tiene_funcion(p_org uuid, p_funcion text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organizaciones o join public.planes p on p.clave = o.plan_clave
    where o.id = p_org and p_funcion = any (p.funciones)
  )
$$;

-- Lanza un error amigable si el usuario no tiene el permiso.
create or replace function public.exigir_permiso(p_org uuid, p_permiso text)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Necesitás iniciar sesión.' using errcode = '28000';
  end if;
  if not public.tiene_permiso(p_org, p_permiso) then
    raise exception 'No tenés permiso para realizar esta acción (%).', p_permiso using errcode = '42501';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Límites del plan (aplicados en la base)
-- -----------------------------------------------------------------------------
create or replace function public.verificar_limite_plan()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_plan public.planes;
  v_limite int;
  v_actual int;
  v_nombre text;
begin
  select p.* into v_plan from public.planes p
    join public.organizaciones o on o.plan_clave = p.clave
   where o.id = new.organizacion_id;

  if tg_table_name = 'sucursales' then
    v_limite := v_plan.max_sucursales; v_nombre := 'sucursales';
    select count(*) into v_actual from public.sucursales where organizacion_id = new.organizacion_id and activo;
  elsif tg_table_name = 'espacios' then
    v_limite := v_plan.max_espacios; v_nombre := 'espacios';
    select count(*) into v_actual from public.espacios where organizacion_id = new.organizacion_id and activo;
  elsif tg_table_name = 'membresias' then
    v_limite := v_plan.max_usuarios; v_nombre := 'usuarios';
    select count(*) into v_actual from public.membresias where organizacion_id = new.organizacion_id and activo;
  end if;

  if v_limite is not null and v_actual >= v_limite then
    raise exception 'Tu plan % permite hasta % %. Cambiá de plan para agregar más.', v_plan.nombre, v_limite, v_nombre
      using errcode = 'P0001', hint = 'LIMITE_PLAN';
  end if;
  return new;
end $$;

create trigger membresias_limite before insert on public.membresias
  for each row when (new.activo) execute function public.verificar_limite_plan();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.planes          enable row level security;
alter table public.organizaciones  enable row level security;
alter table public.perfiles        enable row level security;
alter table public.permisos        enable row level security;
alter table public.roles           enable row level security;
alter table public.rol_permisos    enable row level security;
alter table public.roles_plantilla enable row level security;
alter table public.membresias      enable row level security;
alter table public.invitaciones    enable row level security;

create policy planes_lectura on public.planes for select to authenticated using (activo);
create policy permisos_lectura on public.permisos for select to authenticated using (true);
create policy plantilla_lectura on public.roles_plantilla for select to authenticated using (true);

-- Organizaciones: se crean solo vía crear_organizacion(); no se borran desde el cliente.
create policy org_lectura on public.organizaciones for select to authenticated
  using ((select public.es_miembro(id)));
create policy org_edicion on public.organizaciones for update to authenticated
  using ((select public.tiene_permiso(id, 'organizacion.editar')))
  with check ((select public.tiene_permiso(id, 'organizacion.editar')));

-- Columnas sensibles de la organización: solo se modifican por RPC.
create or replace function public.proteger_organizacion()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and (
       new.plan_clave is distinct from old.plan_clave
    or new.suscripcion_estado is distinct from old.suscripcion_estado
    or new.prueba_hasta is distinct from old.prueba_hasta
    or new.estado is distinct from old.estado
    or new.baja_solicitada_at is distinct from old.baja_solicitada_at
    or new.creado_por is distinct from old.creado_por) then
    raise exception 'Estos datos de la cuenta solo pueden cambiarse desde la sección Plan o Baja.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger organizaciones_proteger before update on public.organizaciones
  for each row execute function public.proteger_organizacion();

-- Perfiles: cada uno ve el suyo y los de sus compañeros de organización.
create policy perfiles_propio on public.perfiles for select to authenticated
  using (id = (select auth.uid()) or exists (
    select 1 from public.membresias m1
    join public.membresias m2 on m2.organizacion_id = m1.organizacion_id
    where m1.usuario_id = (select auth.uid()) and m1.activo and m2.usuario_id = perfiles.id));
create policy perfiles_edicion on public.perfiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy roles_lectura on public.roles for select to authenticated
  using ((select public.es_miembro(organizacion_id)));
create policy roles_alta on public.roles for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'roles.gestionar'))
              and not es_sistema
              and (select public.org_tiene_funcion(organizacion_id, 'roles_personalizados')));
create policy roles_edicion on public.roles for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'roles.gestionar')) and not es_sistema)
  with check (not es_sistema);
create policy roles_baja on public.roles for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'roles.gestionar')) and not es_sistema);

create policy rol_permisos_lectura on public.rol_permisos for select to authenticated
  using ((select public.es_miembro(organizacion_id)));
create policy rol_permisos_alta on public.rol_permisos for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'roles.gestionar')));
create policy rol_permisos_baja on public.rol_permisos for delete to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'roles.gestionar')));

-- El rol propietario es inmutable: garantiza que siempre exista alguien con control total.
-- SECURITY INVOKER a propósito: current_user distingue al usuario de la API ('authenticated')
-- de las RPC internas SECURITY DEFINER ('postgres').
create or replace function public.proteger_rol_propietario()
returns trigger language plpgsql set search_path = '' as $$
declare v_clave text;
begin
  select clave into v_clave from public.roles where id = coalesce(new.rol_id, old.rol_id);
  if v_clave = 'propietario' and current_user in ('authenticated', 'anon') then
    raise exception 'Los permisos del rol Propietario no se pueden modificar.' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
create trigger rol_permisos_proteger before insert or delete on public.rol_permisos
  for each row execute function public.proteger_rol_propietario();

create policy membresias_lectura on public.membresias for select to authenticated
  using (usuario_id = (select auth.uid()) or (select public.es_miembro(organizacion_id)));
create policy membresias_edicion on public.membresias for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')));
-- Altas: solo vía crear_organizacion() o aceptar_invitacion(). Bajas: desactivando.

-- SECURITY INVOKER a propósito: current_user distingue al usuario de la API ('authenticated')
-- de las RPC internas SECURITY DEFINER ('postgres').
create or replace function public.proteger_membresia()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_era_prop boolean;
  v_es_prop  boolean;
  v_restantes int;
begin
  if new.usuario_id <> old.usuario_id or new.organizacion_id <> old.organizacion_id then
    raise exception 'No se puede reasignar una membresía.' using errcode = '42501';
  end if;
  select r.clave = 'propietario' into v_era_prop from public.roles r where r.id = old.rol_id;
  select r.clave = 'propietario' into v_es_prop  from public.roles r where r.id = new.rol_id;
  if (v_es_prop or v_era_prop) and current_user in ('authenticated', 'anon')
     and not public.es_propietario(new.organizacion_id) then
    raise exception 'Solo un propietario puede asignar o quitar el rol Propietario.' using errcode = '42501';
  end if;
  if v_era_prop and (not v_es_prop or not new.activo) then
    select count(*) into v_restantes from public.membresias m join public.roles r on r.id = m.rol_id
     where m.organizacion_id = new.organizacion_id and m.activo and r.clave = 'propietario' and m.id <> new.id;
    if v_restantes = 0 then
      raise exception 'La organización debe tener al menos un propietario activo.' using errcode = 'P0001';
    end if;
  end if;
  if new.activo and not old.activo then
    perform public.verificar_limite_plan_membresia(new.organizacion_id);
  end if;
  return new;
end $$;

create or replace function public.verificar_limite_plan_membresia(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_limite int; v_actual int;
begin
  select p.max_usuarios into v_limite from public.planes p join public.organizaciones o on o.plan_clave = p.clave where o.id = p_org;
  select count(*) into v_actual from public.membresias where organizacion_id = p_org and activo;
  if v_limite is not null and v_actual >= v_limite then
    raise exception 'Tu plan permite hasta % usuarios activos.', v_limite using errcode = 'P0001', hint = 'LIMITE_PLAN';
  end if;
end $$;

create trigger membresias_proteger before update on public.membresias
  for each row execute function public.proteger_membresia();

create policy invitaciones_lectura on public.invitaciones for select to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')));
create policy invitaciones_alta on public.invitaciones for insert to authenticated
  with check ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')) and creada_por = (select auth.uid()));
create policy invitaciones_edicion on public.invitaciones for update to authenticated
  using ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')))
  with check ((select public.tiene_permiso(organizacion_id, 'usuarios.gestionar')));

-- SECURITY INVOKER a propósito: current_user distingue al usuario de la API ('authenticated')
-- de las RPC internas SECURITY DEFINER ('postgres').
create or replace function public.proteger_invitacion()
returns trigger language plpgsql set search_path = '' as $$
declare v_clave text;
begin
  select clave into v_clave from public.roles where id = new.rol_id;
  if v_clave = 'propietario' and current_user in ('authenticated', 'anon')
     and not public.es_propietario(new.organizacion_id) then
    raise exception 'Solo un propietario puede invitar a otro propietario.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger invitaciones_proteger before insert or update on public.invitaciones
  for each row execute function public.proteger_invitacion();
