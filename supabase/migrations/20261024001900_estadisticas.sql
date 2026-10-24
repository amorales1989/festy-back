-- =============================================================================
-- Festy · Migración 19: estadísticas de la empresa.
--
-- Un solo SP devuelve todo lo de la pantalla Estadísticas para un período y lo
-- compara con el período anterior de igual duración. Corre con la identidad
-- del usuario (RLS): exige ver eventos, y lo de dinero solo se incluye si el rol
-- puede ver cobros (pagos.ver) o gastos (gastos.ver); si no, esas partes van en null.
--
-- Definiciones:
--   * evento del período: fecha del evento (en la zona de la empresa) dentro del
--     rango y estado señada, confirmada o finalizada;
--   * facturado: total de esos eventos; cobrado y gastos: por fecha de cobro/gasto;
--   * consultas: reservas creadas en el período (cualquier estado);
--   * conversión: de esas consultas, las que hoy están señadas, confirmadas o finalizadas.
-- =============================================================================

create or replace function api.sp_estadisticas(p_org uuid, p_desde date, p_hasta date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_tz text;
  v_dias int := p_hasta - p_desde + 1;
  v_ant_desde date := p_desde - (p_hasta - p_desde + 1);
  v_ant_hasta date := p_desde - 1;
  v_pagos boolean := public.tiene_permiso(p_org, 'pagos.ver');
  v_gastos boolean := public.tiene_permiso(p_org, 'gastos.ver');
  v_semanal boolean := (p_hasta - p_desde) <= 62;
begin
  if not public.tiene_permiso(p_org, 'reservas.ver') then
    raise exception 'Necesitás permiso para ver eventos.' using errcode = '42501';
  end if;
  if p_hasta < p_desde or p_hasta - p_desde > 3660 then
    raise exception 'Rango de fechas inválido.' using errcode = '22023';
  end if;
  select zona_horaria into v_tz from public.organizaciones where id = p_org;

  return (
    with
    ev as (   -- eventos señados, confirmados o finalizados de ambos períodos
      select r.*, (r.inicio at time zone v_tz)::date as dia, (r.inicio at time zone v_tz)::date >= p_desde as actual
        from public.reservas r
       where r.organizacion_id = p_org and r.estado in ('senada','confirmada','finalizada')
         and (r.inicio at time zone v_tz)::date between v_ant_desde and p_hasta
    ),
    eva as (select * from ev where actual),
    consultas as (
      select r.*, (r.creado_at at time zone v_tz)::date >= p_desde as actual
        from public.reservas r
       where r.organizacion_id = p_org and (r.creado_at at time zone v_tz)::date between v_ant_desde and p_hasta
    ),
    pg as (
      select p.*, p.fecha >= p_desde as actual from public.pagos p
       where v_pagos and p.organizacion_id = p_org and not p.anulado and p.fecha between v_ant_desde and p_hasta
    ),
    gs as (
      select g.*, g.fecha >= p_desde as actual from public.gastos g
       where v_gastos and g.organizacion_id = p_org and g.fecha between v_ant_desde and p_hasta
    ),
    costos as (
      select coalesce(sum(c.monto), 0) as total from public.costos_evento c where c.reserva_id in (select id from eva)
    ),
    tramos as (   -- semanas o meses del período
      select t::date as desde,
             least(case when v_semanal then (t + interval '6 days')::date else (t + interval '1 month' - interval '1 day')::date end, p_hasta) as hasta
        from generate_series(case when v_semanal then p_desde else date_trunc('month', p_desde)::date end, p_hasta,
                             case when v_semanal then interval '7 days' else interval '1 month' end) t
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', p_desde, 'hasta', p_hasta, 'dias', v_dias),
      'anterior', jsonb_build_object('desde', v_ant_desde, 'hasta', v_ant_hasta),
      'agrupacion', case when v_semanal then 'semana' else 'mes' end,
      'resumen', jsonb_build_object(
        'eventos', (select count(*) from eva),
        'eventos_ant', (select count(*) from ev where not actual),
        'invitados', (select coalesce(sum(invitados), 0) from eva),
        'invitados_promedio', (select round(avg(invitados)) from eva where invitados is not null),
        'consultas', (select count(*) from consultas where actual),
        'consultas_ant', (select count(*) from consultas where not actual),
        'cerradas', (select count(*) from consultas where actual and estado in ('senada','confirmada','finalizada')),
        'cerradas_ant', (select count(*) from consultas where not actual and estado in ('senada','confirmada','finalizada')),
        'canceladas', (select count(*) from consultas where actual and estado = 'cancelada'),
        'pedidos_web', (select count(*) from consultas where actual and pedido_web is not null),
        -- eventos cargados después de su fecha (migraciones de datos viejos) no cuentan
        'anticipacion_dias', (select round(avg(dia - (creado_at at time zone v_tz)::date)) from eva where (creado_at at time zone v_tz)::date <= dia),
        'clientes_nuevos', (select count(*) from public.clientes c where c.organizacion_id = p_org
                              and (c.creado_at at time zone v_tz)::date between p_desde and p_hasta),
        'presupuestos_creados', (select count(*) from public.presupuestos p where p.organizacion_id = p_org
                                   and (p.creado_at at time zone v_tz)::date between p_desde and p_hasta),
        'presupuestos_aceptados', (select count(*) from public.presupuestos p where p.organizacion_id = p_org and p.estado = 'aceptado'
                                     and (p.creado_at at time zone v_tz)::date between p_desde and p_hasta),
        'facturado', case when v_pagos then (select coalesce(sum(precio_total), 0) from eva) end,
        'facturado_ant', case when v_pagos then (select coalesce(sum(precio_total), 0) from ev where not actual) end,
        'ticket_promedio', case when v_pagos then (select round(avg(precio_total)) from eva) end,
        'ticket_promedio_ant', case when v_pagos then (select round(avg(precio_total)) from ev where not actual) end,
        'cobrado', case when v_pagos then (select coalesce(sum(monto), 0) from pg where actual) end,
        'cobrado_ant', case when v_pagos then (select coalesce(sum(monto), 0) from pg where not actual) end,
        'gastos', case when v_gastos then (select coalesce(sum(monto), 0) from gs where actual) end,
        'gastos_ant', case when v_gastos then (select coalesce(sum(monto), 0) from gs where not actual) end,
        'costos_eventos', case when v_gastos and v_pagos then (select total from costos) end,
        'ganancia_eventos', case when v_gastos and v_pagos then (select coalesce(sum(precio_total), 0) from eva) - (select total from costos) end,
        'por_cobrar', case when v_pagos then (select coalesce(sum(s.saldo), 0) from public.v_reservas_saldo s join public.reservas r on r.id = s.reserva_id
                                                where r.organizacion_id = p_org and r.estado in ('senada','confirmada','finalizada')) end),
      'series', (select api.lista(jsonb_agg(jsonb_build_object(
          'desde', t.desde, 'hasta', t.hasta,
          'eventos', (select count(*) from eva where dia between t.desde and t.hasta),
          'facturado', case when v_pagos then (select coalesce(sum(precio_total), 0) from eva where dia between t.desde and t.hasta) end,
          'cobrado', case when v_pagos then (select coalesce(sum(monto), 0) from pg where actual and fecha between t.desde and t.hasta) end,
          'gastos', case when v_gastos then (select coalesce(sum(monto), 0) from gs where actual and fecha between t.desde and t.hasta) end)
          order by t.desde)) from tramos t),
      'embudo', jsonb_build_object(
        'consultas', (select count(*) from consultas where actual),
        'retenidas', (select count(*) from consultas where actual and estado in ('tentativa','senada','confirmada','finalizada')),
        'senadas', (select count(*) from consultas where actual and estado in ('senada','confirmada','finalizada')),
        'confirmadas', (select count(*) from consultas where actual and estado in ('confirmada','finalizada'))),
      'por_tipo', (select api.lista(jsonb_agg(x order by (x->>'eventos')::int desc, (x->>'facturado')::numeric desc nulls last)) from (
          select jsonb_build_object('tipo', tipo_evento, 'eventos', count(*),
                                    'facturado', case when v_pagos then sum(precio_total) end) x
            from eva group by tipo_evento order by count(*) desc) t),
      'por_espacio', (select api.lista(jsonb_agg(jsonb_build_object('espacio', e.nombre, 'eventos', x.eventos, 'dias_ocupados', x.dias,
                          'ocupacion', round(x.dias * 100.0 / v_dias, 1),
                          'facturado', case when v_pagos then x.facturado end) order by x.eventos desc))
          from (select re.espacio_id, count(distinct eva.id) as eventos, count(distinct eva.dia) as dias, sum(eva.precio_total) as facturado
                  from eva join public.reserva_espacios re on re.reserva_id = eva.id group by re.espacio_id) x
          join public.espacios e on e.id = x.espacio_id),
      'por_dia_semana', (select api.lista(jsonb_agg(jsonb_build_object('dia', d, 'eventos',
                            (select count(*) from eva where extract(isodow from dia) = d)) order by d))
                           from generate_series(1, 7) d),
      'origen_clientes', (select api.lista(jsonb_agg(jsonb_build_object('origen', coalesce(origen, 'sin_dato'), 'clientes', n) order by n desc))
          from (select c.origen, count(*) as n from public.clientes c where c.organizacion_id = p_org
                   and (c.creado_at at time zone v_tz)::date between p_desde and p_hasta group by c.origen) o),
      'medios_pago', case when v_pagos then (select api.lista(jsonb_agg(jsonb_build_object('medio', medio, 'monto', m) order by m desc))
          from (select medio, sum(monto) as m from pg where actual group by medio) x) end,
      'gastos_categoria', case when v_gastos then (select api.lista(jsonb_agg(jsonb_build_object('categoria', categoria, 'monto', m) order by m desc))
          from (select categoria, sum(monto) as m from gs where actual group by categoria) x) end,
      'top_clientes', (select api.lista(jsonb_agg(jsonb_build_object('cliente', c.nombre, 'id', c.id, 'eventos', x.n,
                          'facturado', case when v_pagos then x.f end) order by x.f desc, x.n desc))
          from (select cliente_id, count(*) as n, sum(precio_total) as f from eva where cliente_id is not null
                 group by cliente_id order by sum(precio_total) desc, count(*) desc limit 8) x
          join public.clientes c on c.id = x.cliente_id)
    )
  );
end $$;

revoke execute on function api.sp_estadisticas(uuid, date, date) from public, anon;
grant execute on function api.sp_estadisticas(uuid, date, date) to authenticated;
