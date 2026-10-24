-- =============================================================================
-- Festy · Migración 2: sedes.
-- Jerarquía: organización → salón (marca/unidad de negocio) → sucursal
-- (dirección física) → espacio (lo que se reserva). Los recursos (vajilla,
-- sonido, mobiliario) pertenecen a una sucursal.
-- =============================================================================

create table public.salones (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  nombre          text not null check (length(trim(nombre)) between 2 and 120),
  descripcion     text,
  activo          boolean not null default true,
  es_ejemplo      boolean not null default false,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id)
);

create table public.sucursales (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  salon_id        uuid not null,
  nombre          text not null check (length(trim(nombre)) between 2 and 120),
  direccion       text,
  localidad       text,
  provincia       text,
  telefono        text,
  -- null = usa la zona horaria de la organización
  zona_horaria    text,
  activo          boolean not null default true,
  es_ejemplo      boolean not null default false,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id),
  foreign key (organizacion_id, salon_id) references public.salones(organizacion_id, id) on delete cascade
);
create index sucursales_salon_idx on public.sucursales (salon_id);

create table public.espacios (
  id                uuid primary key default gen_random_uuid(),
  organizacion_id   uuid not null references public.organizaciones(id) on delete cascade,
  sucursal_id       uuid not null,
  nombre            text not null check (length(trim(nombre)) between 2 and 120),
  tipo              text not null default 'salon'
                      check (tipo in ('salon','quincho','jardin','terraza','sala','auditorio','otro')),
  descripcion       text,
  capacidad_maxima  int not null check (capacidad_maxima between 1 and 100000),
  color             text not null default '#7c3aed' check (color ~ '^#[0-9a-fA-F]{6}$'),
  -- tiempos operativos en minutos
  preparacion_min   int not null default 0  check (preparacion_min between 0 and 2880),
  montaje_min       int not null default 60 check (montaje_min between 0 and 2880),
  desmontaje_min    int not null default 60 check (desmontaje_min between 0 and 2880),
  limpieza_min      int not null default 60 check (limpieza_min between 0 and 2880),
  duracion_minima_min int not null default 60 check (duracion_minima_min between 15 and 20160),
  duracion_sugerida_min int not null default 300 check (duracion_sugerida_min between 15 and 20160),
  activo            boolean not null default true,
  es_ejemplo        boolean not null default false,
  creado_at         timestamptz not null default now(),
  actualizado_at    timestamptz not null default now(),
  unique (organizacion_id, id),
  foreign key (organizacion_id, sucursal_id) references public.sucursales(organizacion_id, id) on delete cascade
);
create index espacios_sucursal_idx on public.espacios (sucursal_id);

-- Horario de atención por día (0 = domingo … 6 = sábado). Si hora_hasta <= hora_desde
-- el horario cruza la medianoche (ej.: 20:00 a 05:00).
create table public.espacio_horarios (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null,
  espacio_id      uuid not null,
  dia_semana      smallint not null check (dia_semana between 0 and 6),
  hora_desde      time not null,
  hora_hasta      time not null,
  unique (espacio_id, dia_semana, hora_desde),
  foreign key (organizacion_id, espacio_id) references public.espacios(organizacion_id, id) on delete cascade
);

create table public.recursos (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid not null references public.organizaciones(id) on delete cascade,
  sucursal_id     uuid not null,
  nombre          text not null check (length(trim(nombre)) between 2 and 120),
  categoria       text not null default 'otro'
                    check (categoria in ('mobiliario','vajilla','sonido','iluminacion','decoracion','cocina','otro')),
  cantidad        int not null default 1 check (cantidad >= 0),
  notas           text,
  activo          boolean not null default true,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now(),
  unique (organizacion_id, id),
  foreign key (organizacion_id, sucursal_id) references public.sucursales(organizacion_id, id) on delete cascade
);

-- Feriados: organizacion_id null = feriado nacional (lectura para todos, solo
-- lo carga la plataforma). Los de la organización se gestionan desde la app.
create table public.feriados (
  id              uuid primary key default gen_random_uuid(),
  organizacion_id uuid references public.organizaciones(id) on delete cascade,
  fecha           date not null,
  nombre          text not null,
  creado_at       timestamptz not null default now()
);
create unique index feriados_unicos on public.feriados (coalesce(organizacion_id, '00000000-0000-0000-0000-000000000000'::uuid), fecha);

-- Feriados nacionales inamovibles de Argentina 2026 (Ley 27.399). Los feriados
-- trasladables (17/6, 17/8, 12/10, 20/11) y los días no laborables con fines
-- turísticos dependen del decreto anual y NO se cargan aquí: deben verificarse
-- con la publicación oficial y agregarse desde Configuración → Feriados.
insert into public.feriados (organizacion_id, fecha, nombre) values
  (null, '2026-01-01', 'Año Nuevo'),
  (null, '2026-02-16', 'Carnaval'),
  (null, '2026-02-17', 'Carnaval'),
  (null, '2026-03-24', 'Día Nacional de la Memoria por la Verdad y la Justicia'),
  (null, '2026-04-02', 'Día del Veterano y de los Caídos en la Guerra de Malvinas'),
  (null, '2026-04-03', 'Viernes Santo'),
  (null, '2026-05-01', 'Día del Trabajador'),
  (null, '2026-05-25', 'Día de la Revolución de Mayo'),
  (null, '2026-06-20', 'Paso a la Inmortalidad del Gral. Manuel Belgrano'),
  (null, '2026-07-09', 'Día de la Independencia'),
  (null, '2026-12-08', 'Inmaculada Concepción de María'),
  (null, '2026-12-25', 'Navidad');

-- Triggers
create trigger salones_actualizado    before update on public.salones    for each row execute function public.tocar_actualizado();
create trigger sucursales_actualizado before update on public.sucursales for each row execute function public.tocar_actualizado();
create trigger espacios_actualizado   before update on public.espacios   for each row execute function public.tocar_actualizado();
create trigger recursos_actualizado   before update on public.recursos   for each row execute function public.tocar_actualizado();
create trigger sucursales_zona_horaria before insert or update of zona_horaria on public.sucursales
  for each row execute function public.validar_zona_horaria();

create trigger sucursales_limite before insert on public.sucursales
  for each row when (new.activo) execute function public.verificar_limite_plan();
create trigger espacios_limite before insert on public.espacios
  for each row when (new.activo) execute function public.verificar_limite_plan();

-- Un segundo salón (marca) requiere la función multi_salon del plan.
create or replace function public.verificar_multi_salon()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.salones where organizacion_id = new.organizacion_id)
     and not public.org_tiene_funcion(new.organizacion_id, 'multi_salon') then
    raise exception 'Tu plan permite un solo salón. Cambiá de plan para administrar varios.'
      using errcode = 'P0001', hint = 'LIMITE_PLAN';
  end if;
  return new;
end $$;
create trigger salones_limite before insert on public.salones
  for each row execute function public.verificar_multi_salon();

-- RLS
alter table public.salones          enable row level security;
alter table public.sucursales       enable row level security;
alter table public.espacios         enable row level security;
alter table public.espacio_horarios enable row level security;
alter table public.recursos         enable row level security;
alter table public.feriados         enable row level security;

do $$
declare t text;
begin
  foreach t in array array['salones','sucursales','espacios','espacio_horarios','recursos'] loop
    execute format('create policy %1$s_lectura on public.%1$s for select to authenticated
                      using ((select public.es_miembro(organizacion_id)))', t);
    execute format('create policy %1$s_alta on public.%1$s for insert to authenticated
                      with check ((select public.tiene_permiso(organizacion_id, ''sedes.gestionar'')))', t);
    execute format('create policy %1$s_edicion on public.%1$s for update to authenticated
                      using ((select public.tiene_permiso(organizacion_id, ''sedes.gestionar'')))
                      with check ((select public.tiene_permiso(organizacion_id, ''sedes.gestionar'')))', t);
    execute format('create policy %1$s_baja on public.%1$s for delete to authenticated
                      using ((select public.tiene_permiso(organizacion_id, ''sedes.gestionar'')))', t);
  end loop;
end $$;

create policy feriados_lectura on public.feriados for select to authenticated
  using (organizacion_id is null or (select public.es_miembro(organizacion_id)));
create policy feriados_alta on public.feriados for insert to authenticated
  with check (organizacion_id is not null and (select public.tiene_permiso(organizacion_id, 'sedes.gestionar')));
create policy feriados_baja on public.feriados for delete to authenticated
  using (organizacion_id is not null and (select public.tiene_permiso(organizacion_id, 'sedes.gestionar')));
