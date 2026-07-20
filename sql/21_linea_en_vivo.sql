-- ============================================================================
-- 21_linea_en_vivo.sql  (v161)
-- Vista "Línea en vivo" (monitor tipo SONAR): por cada ruta, una línea horizontal
-- con TODOS los puntos de control y cada bus ubicado ENCIMA del punto donde va,
-- con su hora y si va adelantado / a tiempo / atrasado, más el resumen por ruta.
--
-- Solo LEE caches (moviles_operacion + itinerario_puntos), sin llamar a SONAR:
-- rápido (<50 ms) y seguro para el cliente. El progreso ya lo precalcula el cron
-- de 20_recorrido_vivo.sql; aquí se le agrega el ÍNDICE del punto (para ubicar el
-- bus sin ambigüedad: los nombres se repiten, p.ej. PARQUE POBLADO en 5 y 12) y la
-- HORA local de ese punto.
-- ============================================================================

-- 1) Nuevas columnas en el caché: índice del último punto alcanzado y su hora local.
alter table public.moviles_operacion add column if not exists par_idx  int;
alter table public.moviles_operacion add column if not exists ult_hora text;

-- 2) El cron de progreso ahora también guarda par_idx (índice) y ult_hora (hora del
--    último punto, en hora Colombia). Reemplaza la versión de 20_recorrido_vivo.sql.
create or replace function public.refrescar_recorrido_vivo_core()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_itid bigint; v_ts timestamptz := now(); v_n int := 0;
begin
  if not pg_try_advisory_xact_lock(724003) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  v_action := rtrim(v_ns, '/') || '/ServiceSoap/GET_ItinerariesHistory_v2';
  v_ini := to_char((now() - interval '18 hours') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char((now() + interval '2 hours')  at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec', '30000', true);

  for v_itid in
    select distinct it_id from public.moviles_operacion where coalesce(it_id, 0) <> 0
  loop
    v_body := '<?xml version="1.0" encoding="utf-8"?>'
      || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '">'
      || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
      || '<Itinerary>' || v_itid || '</Itinerary>'
      || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
      || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
      || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';

    begin
      select content into v_resp from extensions.http((
        'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;
    exception when others then
      continue;
    end;

    with trips as (
      select
        (xpath('/x:ItLog/x:mId/text()',     it, array[array['x', v_ns]]))[1]::text as mid,
        (xpath('/x:ItLog/x:regId/text()',   it, array[array['x', v_ns]]))[1]::text::bigint as regid,
        (xpath('/x:ItLog/x:running/text()', it, array[array['x', v_ns]]))[1]::text as running,
        it as node
      from unnest(xpath('//x:ItLog', v_xml, array[array['x', v_ns]])) as it
    ),
    pts as (
      select t.mid, t.regid,
        (xpath('/x:ItPointLog/x:p_index/text()', p, array[array['x', v_ns]]))[1]::text::int as idx,
        nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text, '')::int as diff,
        nullif((xpath('/x:ItPointLog/x:p_realtime/text()',   p, array[array['x', v_ns]]))[1]::text, '') as p_real
      from trips t, unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', t.node, array[array['x', v_ns]])) as p
      where t.running = 'Y'
    ),
    agg as (
      select mid, max(regid) as regid, count(*) as pas, max(idx) as ult_idx,
             (array_agg(diff   order by idx desc))[1] as atraso,
             (array_agg(p_real order by idx desc))[1] as ult_real
      from pts group by mid
    )
    update public.moviles_operacion m set
      regid = a.regid, par_pasadas = a.pas, par_idx = a.ult_idx, atraso = a.atraso,
      ult_hora = to_char(public._utc_ts(a.ult_real) at time zone 'America/Bogota', 'HH24:MI'),
      ultima_parada = ip.geofence_name, prog_actualizado = v_ts
    from agg a
    left join public.itinerario_puntos ip on ip.it_id = v_itid and ip.point_index = a.ult_idx
    where m.mid = a.mid and m.it_id = v_itid;

    v_n := v_n + 1;
  end loop;

  -- Limpia el progreso de los que ya no van corriendo.
  update public.moviles_operacion set
    regid = null, par_pasadas = null, par_idx = null, atraso = null,
    ultima_parada = null, ult_hora = null
  where prog_actualizado is null or prog_actualizado < v_ts;

  update public.moviles_operacion m set par_total = t.n
  from (select it_id, count(*) n from public.itinerario_puntos group by it_id) t
  where m.it_id = t.it_id;
  update public.moviles_operacion set par_total = null where coalesce(it_id, 0) = 0;

  return jsonb_build_object('ok', true, 'itinerarios', v_n,
    'con_progreso', (select count(*) from public.moviles_operacion where par_pasadas is not null));
end $fn$;

revoke all on function public.refrescar_recorrido_vivo_core() from public, anon, authenticated;

-- 3) LECTOR de la vista de línea (rápido, superset del de la tabla): por cada ruta
--    devuelve los puntos ordenados y los buses con su índice/hora/atraso.
create or replace function public.linea_en_vivo()
returns jsonb
language sql
security definer
set search_path = public
as $fn$
  select case
    when auth.uid() is null then jsonb_build_object('ok', false, 'error', 'No autenticado.')
    else (
      select jsonb_build_object(
        'ok', true,
        'hora', to_char((select max(actualizado) from public.moviles_operacion) at time zone 'America/Bogota', 'HH24:MI:SS'),
        'edad_seg', coalesce(extract(epoch from (now() - (select max(actualizado) from public.moviles_operacion)))::int, 999999),
        'total',   (select count(*) from public.moviles_operacion),
        'en_ruta', (select count(*) from public.moviles_operacion where coalesce(it_id, 0) <> 0),
        'libres',  (select count(*) from public.moviles_operacion where coalesce(it_id, 0) = 0),
        'rutas', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'it_id', g.it_id, 'ruta', g.ruta, 'n', g.n,
                   'atrasados', g.atrasados, 'adelantados', g.adelantados,
                   'puntos', coalesce(p.puntos, '[]'::jsonb),
                   'moviles', g.moviles) order by g.ruta)
          from (
            select it_id, ruta, count(*) as n,
                   count(*) filter (where atraso is not null and atraso >  5) as atrasados,
                   count(*) filter (where atraso is not null and atraso < -1) as adelantados,
                   jsonb_agg(jsonb_build_object(
                     'movil', movil, 'placa', placa, 'conductor', conductor, 'mid', mid,
                     'en_ruta_seg', case when inicio     is not null then extract(epoch from (now() - inicio))::int end,
                     'gps_seg',     case when ultimo_gps is not null then extract(epoch from (now() - ultimo_gps))::int end,
                     'regid', regid, 'par_total', par_total, 'par_pasadas', par_pasadas,
                     'idx', par_idx, 'hora', ult_hora, 'atraso', atraso, 'ultima_parada', ultima_parada
                   ) order by movil) as moviles
            from public.moviles_operacion
            where coalesce(it_id, 0) <> 0
            group by it_id, ruta
          ) g
          left join (
            select it_id, jsonb_agg(jsonb_build_object('idx', point_index, 'nombre', geofence_name) order by point_index) as puntos
            from public.itinerario_puntos group by it_id
          ) p on p.it_id = g.it_id
        ), '[]'::jsonb)
      )
    )
  end
$fn$;

revoke all on function public.linea_en_vivo() from public, anon;
grant execute on function public.linea_en_vivo() to authenticated;

-- 4) Semilla: llena par_idx / ult_hora ya mismo (no esperar al cron de 2 min).
select public.refrescar_recorrido_vivo_core();
