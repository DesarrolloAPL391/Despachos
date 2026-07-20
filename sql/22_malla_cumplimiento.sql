-- ============================================================================
-- 22_malla_cumplimiento.sql  (v163)
-- "Cumplimiento por puntos" (malla tipo SONAR "Definición de colores"):
-- por una RUTA y una FECHA, devuelve TODOS los viajes del día (filas) con la hora
-- real y la desviación en minutos en CADA punto de control (columnas), para pintar
-- una malla coloreada: verde = a tiempo (0), azul = adelantado (<0), rojo =
-- atrasado (>0), gris = sin dato.
--
-- Fuente: GET_ItinerariesHistory_v2(Itinerary, ventana del día en UTC) SIN mId trae
-- TODOS los viajes de esa ruta. Medido: ~0.8 s para un día completo (36 viajes),
-- muy por debajo del statement_timeout=8s → se puede llamar EN VIVO desde el cliente.
-- p_difference viene firmado (negativo = adelantado). El móvil se resuelve por
-- vehiculosgps.tracker_id = mId. Tiempos de SONAR en UTC → hora Colombia.
-- ============================================================================

-- Lista de rutas que tienen itinerario cacheado (para el selector de la vista).
create or replace function public.rutas_itinerario()
returns jsonb language sql security definer set search_path = public as $fn$
  select case when auth.uid() is null then jsonb_build_object('ok', false, 'error', 'No autenticado.')
    else jsonb_build_object('ok', true, 'rutas', coalesce(
      (select jsonb_agg(ruta order by ruta) from (select distinct ruta from public.itinerario_rutas where ruta is not null) r),
      '[]'::jsonb)) end
$fn$;
revoke all on function public.rutas_itinerario() from public, anon;
grant execute on function public.rutas_itinerario() to authenticated;

create or replace function public.malla_cumplimiento(p_ruta text, p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_itid bigint; v_itids bigint[]; v_viajes jsonb := '[]'::jsonb; v_puntos jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  if coalesce(p_ruta, '') = '' then return jsonb_build_object('ok', false, 'error', 'Falta la ruta.'); end if;
  if p_fecha is null then p_fecha := (now() at time zone 'America/Bogota')::date; end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  select array_agg(it_id) into v_itids from public.itinerario_rutas where ruta = p_ruta;
  if v_itids is null then return jsonb_build_object('ok', false, 'error', 'Esa ruta no tiene itinerario en SONAR.'); end if;

  v_action := rtrim(v_ns, '/') || '/ServiceSoap/GET_ItinerariesHistory_v2';
  v_ini := to_char((p_fecha::timestamp     at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha + 1)::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec', '12000', true);

  foreach v_itid in array v_itids loop
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

    v_viajes := v_viajes || coalesce((
      select jsonb_agg(jsonb_build_object(
        'hora',  to_char(public._utc_ts((xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text) at time zone 'America/Bogota', 'HH24:MI'),
        'sort',  (xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text,
        'mid',   (xpath('/x:ItLog/x:mId/text()',   it, array[array['x', v_ns]]))[1]::text,
        'movil', (select v.movil from public.vehiculosgps v where v.tracker_id::text = (xpath('/x:ItLog/x:mId/text()', it, array[array['x', v_ns]]))[1]::text limit 1),
        'regid', (xpath('/x:ItLog/x:regId/text()', it, array[array['x', v_ns]]))[1]::text,
        'running', (xpath('/x:ItLog/x:running/text()', it, array[array['x', v_ns]]))[1]::text,
        'canceled', (xpath('/x:ItLog/x:canceled/text()', it, array[array['x', v_ns]]))[1]::text,
        'celdas', (select jsonb_object_agg(idx::text, jsonb_build_object('h', h, 'd', d)) from (
            select (xpath('/x:ItPointLog/x:p_index/text()', p, array[array['x', v_ns]]))[1]::text::int as idx,
                   to_char(public._utc_ts((xpath('/x:ItPointLog/x:p_realtime/text()', p, array[array['x', v_ns]]))[1]::text) at time zone 'America/Bogota', 'HH24:MI:SS') as h,
                   nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text, '')::int as d
            from unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', it, array[array['x', v_ns]])) as p
          ) c where h is not null)
      ) order by (xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text)
      from unnest(xpath('//x:ItLog', v_xml, array[array['x', v_ns]])) as it
    ), '[]'::jsonb);
  end loop;

  -- Puntos (encabezado) del itinerario con más puntos entre los de la ruta.
  select jsonb_agg(jsonb_build_object('idx', point_index, 'nombre', geofence_name) order by point_index)
    into v_puntos
  from public.itinerario_puntos
  where it_id = (select it_id from public.itinerario_puntos where it_id = any(v_itids) group by it_id order by count(*) desc limit 1);

  return jsonb_build_object('ok', true, 'ruta', p_ruta, 'fecha', p_fecha,
    'puntos', coalesce(v_puntos, '[]'::jsonb), 'viajes', v_viajes);
end $fn$;

revoke all on function public.malla_cumplimiento(text, date) from public, anon;
grant execute on function public.malla_cumplimiento(text, date) to authenticated;

drop function if exists public._probe_malla(text, date);
