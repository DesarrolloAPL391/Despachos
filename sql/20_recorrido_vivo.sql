-- ============================================================================
-- 20_recorrido_vivo.sql  (v158)
-- Precalcula el PROGRESO del recorrido de TODOS los buses en ruta, para verlo en
-- la tabla de "Rutas en vivo" SIN hacer clic.
--
-- Clave de eficiencia: GET_ItinerariesHistory_v2 con Itinerary y SIN mId devuelve
-- TODOS los viajes de esa ruta (todos los buses) en una sola llamada (~0.5 s).
-- Así, con ~23 itinerarios activos, se cubre toda la flota en ~12 s. Se corre por
-- cron cada 2 min y escribe el progreso en las columnas de public.moviles_operacion
-- (regid, par_total, par_pasadas, atraso, ultima_parada) que lee rutas_en_vivo().
--
-- Los tiempos de SONAR son UTC; aquí solo interesan índices y minutos de atraso.
-- Reutiliza itinerario_puntos (nombres) de 19_recorrido_bus.sql.
-- ============================================================================

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

  -- Una llamada por itinerario activo (trae todos sus buses).
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
      continue;  -- una ruta que falle no descarta a las demás
    end;

    -- Toma el viaje EN CURSO de cada móvil y resume sus paradas recorridas.
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
        nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text, '')::int as diff
      from trips t, unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', t.node, array[array['x', v_ns]])) as p
      where t.running = 'Y'
    ),
    agg as (
      select mid, max(regid) as regid, count(*) as pas, max(idx) as ult_idx,
             (array_agg(diff order by idx desc))[1] as atraso
      from pts group by mid
    )
    update public.moviles_operacion m set
      regid = a.regid, par_pasadas = a.pas, atraso = a.atraso,
      ultima_parada = ip.geofence_name, prog_actualizado = v_ts
    from agg a
    left join public.itinerario_puntos ip on ip.it_id = v_itid and ip.point_index = a.ult_idx
    where m.mid = a.mid and m.it_id = v_itid;

    v_n := v_n + 1;
  end loop;

  -- Limpia el progreso de los que ya no van corriendo (no refrescados en esta corrida).
  update public.moviles_operacion set
    regid = null, par_pasadas = null, atraso = null, ultima_parada = null
  where prog_actualizado is null or prog_actualizado < v_ts;

  -- par_total = nº de paradas del itinerario de cada móvil (para mostrar "x/y").
  update public.moviles_operacion m set par_total = t.n
  from (select it_id, count(*) n from public.itinerario_puntos group by it_id) t
  where m.it_id = t.it_id;
  update public.moviles_operacion set par_total = null where coalesce(it_id, 0) = 0;

  return jsonb_build_object('ok', true, 'itinerarios', v_n,
    'con_progreso', (select count(*) from public.moviles_operacion where par_pasadas is not null));
end $fn$;

revoke all on function public.refrescar_recorrido_vivo_core() from public, anon, authenticated;

-- Cron: cada 2 minutos precalcula el progreso de todos los buses en ruta.
select cron.schedule('refrescar-recorrido-vivo', '*/2 * * * *',
                     'select public.refrescar_recorrido_vivo_core();');

-- Semilla: llena el progreso ya mismo.
select public.refrescar_recorrido_vivo_core();
