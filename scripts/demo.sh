#!/usr/bin/env bash
# Crea (o recrea) una cuenta demo con datos ficticios para ver el frontend.
#   Usuario: demo@festy.local   Contraseña: demo1234
# Uso: scripts/demo.sh            (requiere `supabase start`)
# Todo lo que crea queda marcado como ejemplo cuando el modelo lo permite.
set -euo pipefail
export PGPASSWORD="${PGPASSWORD:-postgres}"  # clave por defecto del Supabase local
DB="psql -h 127.0.0.1 -p ${DB_PORT:-64322} -U postgres -v ON_ERROR_STOP=1 -qtA"
API="${API_URL:-http://127.0.0.1:64321}"
CLAVE_PUBLICA=$(supabase status -o env 2>/dev/null | sed -n 's/^PUBLISHABLE_KEY="\(.*\)"$/\1/p')
EMAIL="demo@festy.local"
PASS="demo1234"

# Recrear desde cero: borra la cuenta demo anterior y sus organizaciones.
VIEJO=$($DB -c "select id from auth.users where email = '$EMAIL'")
if [ -n "$VIEJO" ]; then
  $DB <<SQL >/dev/null
delete from public.garantias where organizacion_id in (select id from public.organizaciones where creado_por = '$VIEJO');
delete from public.pagos    where organizacion_id in (select id from public.organizaciones where creado_por = '$VIEJO');
delete from public.reservas where organizacion_id in (select id from public.organizaciones where creado_por = '$VIEJO');
delete from public.organizaciones where creado_por = '$VIEJO';
delete from auth.users where email like '%@demo.festy.local' or id = '$VIEJO';
SQL
fi

curl -sf "$API/auth/v1/signup" -H "apikey: $CLAVE_PUBLICA" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"data\":{\"nombre\":\"Valeria Demo\"}}" >/dev/null
U=$($DB -c "select id from auth.users where email = '$EMAIL'")

$DB <<SQL
select set_config('request.jwt.claims', json_build_object('sub', '$U', 'role', 'authenticated')::text, false) \g /dev/null
do \$\$
declare
  v_org uuid; v_salon uuid; v_centro uuid; v_country uuid;
  v_salon_ppal uuid; v_quincho uuid; v_jardin uuid;
  v_tz text := 'America/Argentina/Cordoba';
  v_hoy date := (now() at time zone 'America/Argentina/Cordoba')::date;
  v_cli uuid; v_r uuid; d record; i int := 0;
begin
  v_org := public.crear_organizacion('Quinta Los Álamos', v_tz);
  update public.organizaciones set cuit = '30-71234567-8', telefono = '+54 351 555-0000',
         razon_social = 'Los Álamos Eventos S.R.L.' where id = v_org;

  insert into public.salones (organizacion_id, nombre) values (v_org, 'Los Álamos') returning id into v_salon;
  insert into public.sucursales (organizacion_id, salon_id, nombre, direccion, localidad, provincia)
    values (v_org, v_salon, 'Sede Centro', 'Bv. San Juan 1200', 'Córdoba', 'Córdoba') returning id into v_centro;
  insert into public.sucursales (organizacion_id, salon_id, nombre, direccion, localidad, provincia)
    values (v_org, v_salon, 'Sede Country', 'Ruta E-55 km 12', 'Mendiolaza', 'Córdoba') returning id into v_country;
  insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima, color)
    values (v_org, v_centro, 'Salón principal', 'salon', 180, '#7c3aed') returning id into v_salon_ppal;
  insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima, color, montaje_min, limpieza_min)
    values (v_org, v_centro, 'Quincho', 'quincho', 50, '#0d9488', 30, 30) returning id into v_quincho;
  insert into public.espacios (organizacion_id, sucursal_id, nombre, tipo, capacidad_maxima, color, montaje_min, desmontaje_min)
    values (v_org, v_country, 'Jardín de eventos', 'jardin', 300, '#ea580c', 120, 90) returning id into v_jardin;
  insert into public.espacio_horarios (organizacion_id, espacio_id, dia_semana, hora_desde, hora_hasta)
    select v_org, e, dia, '10:00', '05:00' from unnest(array[v_salon_ppal, v_quincho, v_jardin]) e, generate_series(0, 6) dia;

  -- Datos de ejemplo base (reservas, cobros, gastos, tareas) sobre la Sede Centro
  perform public.cargar_datos_ejemplo(v_org);

  -- Más clientes y reservas para llenar el calendario
  for d in select * from (values
    ('Familia Bustos',        'Casamiento Bustos–Ferreyra', 'casamiento',  'confirmada',  5, '20:30'::time, '05:00'::time, 220, 9500000, 'jardin'),
    ('Colegio Monserrat',     'Fiesta de egresados 2026',   'egresados',   'senada',      9, '22:00'::time, '06:00'::time, 160, 6200000, 'salon'),
    ('Agustina Pereyra',      'Los 15 de Agustina',         'quince',      'confirmada', 16, '21:30'::time, '05:30'::time, 170, 5800000, 'salon'),
    ('Tomás Ledesma',         'Cumple 30 de Tomás',         'cumpleanos',  'tentativa',   3, '21:00'::time, '03:00'::time,  45, 1200000, 'quincho'),
    ('Banco del Interior',    'Convención anual',           'corporativo', 'confirmada', 22, '09:00'::time, '18:00'::time, 250, 7400000, 'jardin'),
    ('Rocío y Facundo',       'Casamiento Rocío y Facundo', 'casamiento',  'consulta',   47, '20:00'::time, '05:00'::time, 200, 0,       'jardin'),
    ('Mariela Quiroga',       'Bautismo de Benjamín',       'bautismo',    'confirmada', 10, '12:30'::time, '17:30'::time,  40,  950000, 'quincho'),
    ('Club Atlético Talleres','Cena de fin de año',         'corporativo', 'senada',     54, '21:00'::time, '02:00'::time, 180, 4900000, 'salon'),
    ('Laura Giménez',         'Cumpleaños infantil Mateo',  'infantil',    'confirmada',  2, '16:00'::time, '20:00'::time,  35,  480000, 'quincho'),
    ('Estudio Sánchez',       'Aniversario 25 años',        'aniversario', 'tentativa',  30, '20:30'::time, '02:30'::time, 120, 3100000, 'salon'),
    ('Paula Díaz',            'Consulta 15 años',           'quince',      'consulta',   68, '21:30'::time, '05:30'::time, 150, 0,       'salon'),
    ('Javier Molina',         'Despedida de soltero',       'cumpleanos',  'cancelada',  12, '22:00'::time, '04:00'::time,  30,  600000, 'quincho')
  ) t(cliente, titulo, tipo, estado, dias, hi, hf, inv, precio, esp)
  loop
    i := i + 1;
    insert into public.clientes (organizacion_id, nombre, telefono, email, origen, es_ejemplo)
    values (v_org, d.cliente, format('+54 9 351 555-%s', 2000 + i), format('cliente%s@ejemplo.com', i),
            (array['instagram','whatsapp','recomendacion','web'])[1 + i % 4], true)
    returning id into v_cli;
    begin
      v_r := public.guardar_reserva(v_org, null, jsonb_build_object(
        'sucursal_id', case when d.esp = 'jardin' then v_country else v_centro end,
        'cliente_id', v_cli, 'titulo', d.titulo, 'tipo_evento', d.tipo, 'estado', 'consulta',
        'inicio', (v_hoy + d.dias + d.hi) at time zone v_tz,
        'fin', (v_hoy + d.dias + d.hf + case when d.hf <= d.hi then interval '1 day' else interval '0' end) at time zone v_tz,
        'invitados', d.inv, 'precio_total', d.precio, 'responsable_id', '$U'),
        jsonb_build_array(jsonb_build_object('espacio_id',
          case d.esp when 'jardin' then v_jardin when 'quincho' then v_quincho else v_salon_ppal end)));
      update public.reservas set es_ejemplo = true,
        contrato_estado = case when d.estado = 'confirmada' then 'firmado'::public.estado_contrato
                               when d.estado = 'senada' then 'enviado' else 'pendiente' end
       where id = v_r;
      if d.estado in ('senada', 'confirmada') then
        insert into public.cuotas (organizacion_id, reserva_id, concepto, vencimiento, monto) values
          (v_org, v_r, 'Seña', v_hoy - 30, round(d.precio * 0.3)),
          (v_org, v_r, 'Cuota 1', v_hoy + (d.dias / 2) - 6, round(d.precio * 0.35)),
          (v_org, v_r, 'Saldo', v_hoy + d.dias - 2, d.precio - round(d.precio * 0.3) - round(d.precio * 0.35));
        perform public.registrar_pago(v_r, round(d.precio * 0.3), v_hoy - (5 + i), 'transferencia', 'sena');
        if d.estado = 'confirmada' then
          perform public.registrar_pago(v_r, round(d.precio * 0.2), v_hoy - i, 'mercadopago', 'cuota');
        end if;
      end if;
      update public.reservas set estado = d.estado::public.estado_reserva,
             motivo_cancelacion = case when d.estado = 'cancelada' then 'El cliente cambió de fecha' end
       where id = v_r;
      if d.estado = 'confirmada' then
        insert into public.tareas (organizacion_id, reserva_id, titulo, vence_el, prioridad, asignada_a, es_ejemplo)
        values (v_org, v_r, 'Coordinar proveedores (DJ, catering, ambientación)', v_hoy + d.dias - 5, 'media', '$U', true);
      end if;
    exception when exclusion_violation or check_violation then
      raise notice 'Omitida por conflicto: %', d.titulo;
    end;
  end loop;

  insert into public.bloqueos (organizacion_id, espacio_id, inicio, fin, tipo, motivo)
  values (v_org, v_jardin, (v_hoy + 14)::timestamp at time zone v_tz, (v_hoy + 16)::timestamp at time zone v_tz, 'mantenimiento', 'Resiembra del césped');

  insert into public.gastos (organizacion_id, sucursal_id, fecha, categoria, descripcion, proveedor, monto, es_ejemplo) values
    (v_org, v_centro,  v_hoy - 3,  'personal',      'Mozos evento fin de semana', 'Agencia Servir',   420000, true),
    (v_org, v_country, v_hoy - 8,  'mantenimiento', 'Corte de césped y jardinería', 'Verde Sur',      180000, true),
    (v_org, null,      v_hoy - 11, 'marketing',     'Campaña Instagram octubre',  'Meta',             95000, true),
    (v_org, v_centro,  v_hoy - 1,  'catering',      'Compra de insumos de barra', 'Distribuidora Norte', 310000, true);

  insert into public.tareas (organizacion_id, titulo, vence_el, prioridad, asignada_a, es_ejemplo) values
    (v_org, 'Renovar habilitación municipal', v_hoy + 20, 'alta', '$U', true),
    (v_org, 'Responder consultas de Instagram', v_hoy, 'media', '$U', true),
    (v_org, 'Revisar stock de vajilla', v_hoy - 2, 'baja', null, true);

  -- Marca, catálogo, presupuestos y entrevistas
  update public.organizaciones set direccion = 'Bv. San Juan 1200, Córdoba', color_marca = '#7c3aed', email_contacto = 'hola@losalamos.com.ar' where id = v_org;
  insert into public.servicios (organizacion_id, nombre, descripcion, tipo, categoria, unidad, precio, costo, es_ejemplo) values
    (v_org, 'Fiesta de 15 completa', 'Salón, menú de 4 pasos, barra libre, DJ y ambientación', 'paquete', 'salon', 'persona', 48000, 29000, true),
    (v_org, 'Casamiento clásico', 'Salón, recepción, menú, mesa dulce y barra libre', 'paquete', 'salon', 'persona', 62000, 38000, true),
    (v_org, 'Alquiler del salón', 'Uso del espacio por 8 horas, mobiliario y limpieza', 'servicio', 'salon', 'evento', 1500000, null, true),
    (v_org, 'Menú adultos', 'Recepción, plato principal, postre y café', 'servicio', 'catering', 'persona', 26000, 15000, true),
    (v_org, 'Menú infantil', 'Para menores de 12 años', 'servicio', 'catering', 'persona', 14000, 8000, true),
    (v_org, 'Barra libre 5 horas', 'Tragos clásicos y sin alcohol', 'servicio', 'bebidas', 'persona', 9500, 5000, true),
    (v_org, 'DJ + sonido e iluminación', '6 horas de música', 'servicio', 'musica', 'evento', 650000, 400000, true),
    (v_org, 'Cabina de fotos', 'Fotos impresas ilimitadas', 'adicional', 'fotografia', 'evento', 280000, 150000, true),
    (v_org, 'Mesa dulce', 'Para 100 personas', 'adicional', 'catering', 'evento', 350000, 200000, true),
    (v_org, 'Show de luces LED', '', 'adicional', 'animacion', 'evento', 180000, 90000, true);

  insert into public.clientes (organizacion_id, nombre, telefono, email, origen, es_ejemplo)
  values (v_org, 'Florencia Ibarra', '+54 9 351 555-3001', 'flor.ejemplo@example.com', 'instagram', true) returning id into v_cli;
  declare v_p uuid;
  begin
    v_p := public.guardar_presupuesto(v_org, null, jsonb_build_object('cliente_id', v_cli, 'titulo', 'Los 15 de Martina', 'tipo_evento', 'quince',
      'fecha_evento', v_hoy + 120, 'hora_inicio', '21:30', 'hora_fin', '05:30', 'espacio_id', v_salon_ppal, 'invitados', 140,
      'estado', 'enviado', 'descuento', 300000, 'sena_porcentaje', 30, 'cantidad_cuotas', 3),
      jsonb_build_array(
        jsonb_build_object('descripcion', 'Fiesta de 15 completa - Salón, menú de 4 pasos, barra libre, DJ y ambientación', 'cantidad', 140, 'unidad', 'persona', 'precio_unitario', 48000),
        jsonb_build_object('descripcion', 'Cabina de fotos', 'cantidad', 1, 'unidad', 'evento', 'precio_unitario', 280000),
        jsonb_build_object('descripcion', 'Mesa dulce', 'cantidad', 1, 'unidad', 'evento', 'precio_unitario', 350000)));
    update public.presupuestos set es_ejemplo = true where id = v_p;
  end;
  -- Capacidad mínima y garantía sugerida por espacio
  update public.espacios set capacidad_minima = 80, garantia_sugerida = 300000 where id = v_salon_ppal;
  update public.espacios set capacidad_minima = 15, garantia_sugerida = 100000 where id = v_quincho;
  update public.espacios set capacidad_minima = 100, garantia_sugerida = 500000 where id = v_jardin;
  update public.presupuestos set garantia_monto = 300000 where organizacion_id = v_org;

  -- Servicios contratados y garantías en algunos eventos
  declare v_ev record;
  begin
    for v_ev in select r.id, r.titulo, r.estado, r.fin, r.invitados from public.reservas r
                 where r.organizacion_id = v_org and r.estado in ('senada','confirmada','finalizada') order by r.inicio loop
      if v_ev.titulo = 'Casamiento Bustos–Ferreyra' then
        perform public.agregar_item_reserva(v_ev.id, 'Casamiento clásico - Salón, recepción, menú, mesa dulce y barra libre', 220, 'persona', 42000, null, false, false, null);
        perform public.agregar_item_reserva(v_ev.id, 'Cabina de fotos', 1, 'evento', 280000, null, true, true, null);
      end if;
      perform public.pedir_garantia(v_ev.id, case when v_ev.titulo like '%Casamiento%' or v_ev.titulo like '%Convención%' then 500000 else 300000 end);
      if v_ev.estado <> 'senada' then
        perform public.cobrar_garantia(v_ev.id, v_hoy - 10, 'transferencia', null);
      end if;
    end loop;
  end;
  update public.garantias set es_ejemplo = true where organizacion_id = v_org;

  insert into public.entrevistas (organizacion_id, cliente_id, inicio, modalidad, sucursal_id, motivo, asignada_a, es_ejemplo)
  values (v_org, v_cli, ((v_hoy + 1) + time '18:00') at time zone v_tz, 'presencial', v_centro, 'Visita al salón y degustación', '$U', true);
  insert into public.entrevistas (organizacion_id, contacto_nombre, contacto_telefono, inicio, modalidad, enlace, motivo, asignada_a, es_ejemplo)
  values (v_org, 'Gonzalo Ferreyra', '+54 9 351 555-3002', (v_hoy + time '19:30') at time zone v_tz, 'videollamada', 'https://meet.google.com/abc-defg-hij',
          'Consulta por casamiento', '$U', true);
end \$\$;
SQL

# Compañeros de equipo (para ver roles y el selector de responsables)
for par in "Martín Recepción:recepcion" "Sofía Finanzas:finanzas" "Diego Operativo:operativo"; do
  NOMBRE="${par%%:*}"; ROL="${par##*:}"; MAIL="$(echo "$ROL")@demo.festy.local"
  curl -sf "$API/auth/v1/signup" -H "apikey: $CLAVE_PUBLICA" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$MAIL\",\"password\":\"$PASS\",\"data\":{\"nombre\":\"$NOMBRE\"}}" >/dev/null
  $DB -c "insert into public.membresias (organizacion_id, usuario_id, rol_id)
          select o.id, u.id, r.id from public.organizaciones o, auth.users u, public.roles r
           where o.creado_por = '$U' and u.email = '$MAIL' and r.organizacion_id = o.id and r.clave = '$ROL'" >/dev/null
done

echo "Cuenta demo lista:"
echo "  Propietaria:  $EMAIL / $PASS"
echo "  Otros roles:  recepcion@demo.festy.local, finanzas@demo.festy.local, operativo@demo.festy.local (misma contraseña)"
