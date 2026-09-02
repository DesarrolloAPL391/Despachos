-- 55_despachos_realizados.sql
-- Los despachos TABLA (turno fijo) NO viven en `despachos`: cada puesto los guarda en SU
-- propia tabla (laureles, t_130, ...; ver tablas_despacho). En `despachos` solo va el LIBRE.
-- Por eso el cron de pasajeros y el Top (que solo miraban `despachos`) se saltaban las TABLAS.
--
-- Este helper unifica los despachos REALIZADOS con ruta de TODAS las fuentes (despachos + las
-- tablas de puesto de tablas_despacho), una fila por viaje. Dinámico: si crean un puesto nuevo,
-- entra solo. Lo usan sync_pasajeros_dia (para bajar sus pasajeros) y top_ruta (para atribuir).

-- laureles es la única tabla de puesto sin índice por fecha (20k filas); lo agrego.
create index if not exists laureles_fecha_idx on public.laureles (fecha);

create or replace function public._despachos_realizados(p_d0 date, p_d1 date)
returns table(movil text, fecha date, ruta text)
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  r record;
  v_sql text;
  v_base text;
begin
  -- plantilla por tabla (%1$I = nombre de la tabla). Realizado = DESPACHADO/SI o con regId SONAR.
  v_base := $tpl$
    select trim(v.numero), x.fecha, coalesce(rr.nombre, rp.nombre)
    from public.%1$I x
    join public.vehiculos v on v.id = x.vehiculo_id
    left join public.rutas rr on rr.id = x.ruta_id
    left join public.rutas rp on rp.id = x.ruta_programada_id
    where x.fecha between $1 and $2
      and (x.estado_despacho in ('DESPACHADO','SI') or x.sonar_regid is not null)
      and coalesce(rr.nombre, rp.nombre) is not null
  $tpl$;
  v_sql := format(v_base, 'despachos');
  for r in select t.tabla from public.tablas_despacho t where t.tabla <> 'despachos' loop
    v_sql := v_sql || ' union all ' || format(v_base, r.tabla);
  end loop;
  return query execute v_sql using p_d0, p_d1;
end
$fn$;
revoke all on function public._despachos_realizados(date,date) from public;

-- Sincroniza pasajeros por LOTES desde TODAS las fuentes (despachos + tablas de puesto).
-- Idempotente: llamar hasta que 'faltan' llegue a 0. (Reescribe la versión que solo miraba despachos.)
create or replace function public.sync_pasajeros_dia(p_dias int default 3, p_limit int default 30)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions','vault'
as $function$
declare
  r record; v_res jsonb; v_ok int := 0; v_fail int := 0; v_faltan int;
begin
  perform set_config('statement_timeout','0',true); -- cron/backfill: sin límite (varias llamadas http)
  for r in
    select dr.movil, dr.fecha
    from public._despachos_realizados(current_date - p_dias, current_date - 1) dr
    join public.vehiculosgps g on trim(g.movil) = dr.movil
    where g.tracker_id is not null
      and not exists (select 1 from public.pasajeros_dia pd
                       where trim(pd.movil) = dr.movil and pd.fecha = dr.fecha)
    group by dr.movil, dr.fecha
    order by dr.fecha desc, dr.movil
    limit p_limit
  loop
    v_res := public._pax_dia_movil(r.movil, r.fecha);
    if coalesce((v_res->>'ok')::boolean, false) then
      insert into public.pasajeros_dia (movil, fecha, subidas, bajadas, mid, actualizado)
      values (trim(r.movil), r.fecha, (v_res->>'subidas')::int, (v_res->>'bajadas')::int, v_res->>'mid', now())
      on conflict (movil, fecha) do update
        set subidas = excluded.subidas, bajadas = excluded.bajadas, mid = excluded.mid, actualizado = now();
      v_ok := v_ok + 1;
    else
      v_fail := v_fail + 1;
    end if;
  end loop;
  select count(*) into v_faltan from (
    select dr.movil, dr.fecha
    from public._despachos_realizados(current_date - p_dias, current_date - 1) dr
    join public.vehiculosgps g on trim(g.movil) = dr.movil
    where g.tracker_id is not null
      and not exists (select 1 from public.pasajeros_dia pd
                       where trim(pd.movil) = dr.movil and pd.fecha = dr.fecha)
    group by dr.movil, dr.fecha
  ) q;
  return jsonb_build_object('ok', true, 'procesados', v_ok, 'fallidos', v_fail, 'faltan', v_faltan);
end $function$;
revoke all on function public.sync_pasajeros_dia(int,int) from public;
