#!/usr/bin/env bash
# Prueba de concurrencia real: dos transacciones intentan reservar el mismo
# espacio y horario al mismo tiempo. Debe confirmarse exactamente una.
# Uso: scripts/prueba_concurrencia.sh   (requiere `supabase start`)
set -euo pipefail
export PGPASSWORD="${PGPASSWORD:-postgres}"
DB="psql -h 127.0.0.1 -p ${DB_PORT:-64322} -U postgres -v ON_ERROR_STOP=1 -qtA"

U=$(cat /proc/sys/kernel/random/uuid)
$DB <<SQL >/dev/null
insert into auth.users (id, email, aud, role) values ('$U', 'conc-$U@test.local', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', json_build_object('sub', '$U')::text, false);
select public.crear_organizacion('Concurrencia $U');
SQL
read -r ORG SUC ESP CLI < <($DB -F' ' <<SQL
select set_config('request.jwt.claims', json_build_object('sub', '$U')::text, false) \g /dev/null
with o as (select id from public.organizaciones where creado_por = '$U'),
     sa as (insert into public.salones (organizacion_id, nombre) select id, 'Salón' from o returning id, organizacion_id),
     su as (insert into public.sucursales (organizacion_id, salon_id, nombre) select organizacion_id, id, 'Suc' from sa returning id, organizacion_id),
     es as (insert into public.espacios (organizacion_id, sucursal_id, nombre, capacidad_maxima) select organizacion_id, id, 'Esp', 100 from su returning id, organizacion_id, sucursal_id),
     cl as (insert into public.clientes (organizacion_id, nombre) select id, 'Cliente' from o returning id)
select es.organizacion_id, es.sucursal_id, es.id, cl.id from es, cl;
SQL
)

reservar() {  # $1 = título, $2 = segundos de espera antes del commit
  $DB <<SQL 2>&1
select set_config('request.jwt.claims', json_build_object('sub', '$U')::text, false) \g /dev/null
begin;
select public.guardar_reserva('$ORG', null,
  jsonb_build_object('sucursal_id','$SUC','cliente_id','$CLI','titulo','$1','estado','confirmada',
                     'inicio','2030-01-05 21:00-03','fin','2030-01-06 04:00-03'),
  jsonb_build_array(jsonb_build_object('espacio_id','$ESP'))) \g /dev/null
select pg_sleep($2) \g /dev/null
commit;
SQL
}

confirmar() {  # $1 = id de reserva en consulta, $2 = espera antes del commit
  $DB <<SQL 2>&1
select set_config('request.jwt.claims', json_build_object('sub', '$U')::text, false) \g /dev/null
begin;
update public.reservas set estado = 'confirmada' where id = '$1';
select pg_sleep($2) \g /dev/null
commit;
SQL
}

limpiar() {
  $DB -c "delete from public.reservas where organizacion_id = '$ORG'; delete from public.organizaciones where id = '$ORG'; delete from auth.users where id = '$U'" >/dev/null
}
trap limpiar EXIT
FALLA=0

echo "== Escenario 1: dos altas simultáneas del mismo espacio y horario"
reservar "Primera" 3 > /tmp/festy_conc_1.log & P1=$!
sleep 1
reservar "Segunda" 0 > /tmp/festy_conc_2.log & P2=$!
wait $P1 || true; wait $P2 || true
N=$($DB -c "select count(*) from public.reservas where organizacion_id = '$ORG' and estado = 'confirmada'")
echo "  T1: $(head -c 160 /tmp/festy_conc_1.log | tr '\n' ' ')"
echo "  T2: $(head -c 160 /tmp/festy_conc_2.log | tr '\n' ' ')"
echo "  Confirmadas: $N (esperado 1)"; [ "$N" = "1" ] || FALLA=1

echo "== Escenario 2: dos consultas existentes pasan a confirmada en paralelo (lo resuelve la restricción EXCLUDE)"
$DB -c "delete from public.reservas where organizacion_id = '$ORG'" >/dev/null
crear_consulta() {
  $DB <<SQL | tail -1
select set_config('request.jwt.claims', json_build_object('sub', '$U')::text, false) \g /dev/null
select public.guardar_reserva('$ORG', null,
  jsonb_build_object('sucursal_id','$SUC','cliente_id','$CLI','titulo','$1','estado','consulta',
                     'inicio','2030-02-02 21:00-03','fin','2030-02-03 04:00-03'),
  jsonb_build_array(jsonb_build_object('espacio_id','$ESP')));
SQL
}
C1=$(crear_consulta "Consulta 1"); C2=$(crear_consulta "Consulta 2")
confirmar "$C1" 3 > /tmp/festy_conc_1.log & P1=$!
sleep 1
confirmar "$C2" 0 > /tmp/festy_conc_2.log & P2=$!
wait $P1 || true; wait $P2 || true
N=$($DB -c "select count(*) from public.reservas where organizacion_id = '$ORG' and estado = 'confirmada'")
echo "  T1: $(head -c 160 /tmp/festy_conc_1.log | tr '\n' ' ')"
echo "  T2: $(head -c 160 /tmp/festy_conc_2.log | tr '\n' ' ')"
echo "  Confirmadas: $N (esperado 1)"; [ "$N" = "1" ] || FALLA=1

rm -f /tmp/festy_conc_1.log /tmp/festy_conc_2.log
if [ $FALLA = 0 ]; then echo "RESULTADO: OK — la base impidió la doble reserva concurrente en ambos escenarios."; else echo "RESULTADO: FALLA"; exit 1; fi
