-- ============================================================================
-- 26_despachos_sonar_ruta.sql  (v170)
-- "Despachos de SONAR" por RUTA: en vez de marcar móvil por móvil, se elige una
-- ruta (o varias) y se traen TODOS sus viajes del día de una sola llamada.
-- Usa GET_ItinerariesHistory_v2(Itinerary, ventana) SIN mId (trae todos los buses
-- de la ruta, patrón de malla/laureles), y devuelve los items con la MISMA forma
-- que despachos_sonar (movil, hora, ruta, conductor, minutos, corriendo, cerrado,
-- cancelado) para que la tabla del modal los pinte igual.
--
-- Notas de campos ItLog: running/close/canceled = 'Y'/'N' (se exponen como
-- booleanos para casar con dsEstado del cliente, que hace String(v)==='true');
-- inittime/endtime vienen en UTC → hora Colombia. El conductor no se puede
-- resolver (ItLog trae solo el DOCUMENTO del driver, no el nombre) → va vacío.
-- El móvil se resuelve por vehiculosgps.tracker_id = mId. Ventana = día Colombia→UTC.
-- ============================================================================

create or replace function public.despachos_sonar_ruta(p_ruta text, p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, vault
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_doc xml; v_ini text; v_fin text;
  v_itid bigint; v_items jsonb := '[]'::jsonb; v_part jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  if p_ruta is null or trim(p_ruta) = '' then return jsonb_build_object('ok', false, 'error', 'Falta la ruta.'); end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  if p_fecha is null then p_fecha := (now() at time zone 'America/Bogota')::date; end if;

  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_ItinerariesHistory_v2';
  v_ini := to_char((p_fecha::timestamp     at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha+1)::timestamp at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec','12000',true);

  -- Una ruta puede mapear a más de un itinerario (ej. variantes): se recorren todos.
  for v_itid in
    select it_id from public.itinerario_rutas where lower(trim(ruta)) = lower(trim(p_ruta))
  loop
    v_body := '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_ItinerariesHistory_v2 xmlns="'||v_ns||'"><User>'||public._xmlesc(v_usr)||'</User><Password>'||public._xmlesc(v_pwd)||'</Password>'
      || '<Itinerary>'||v_itid||'</Itinerary><UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
      || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';
    begin
      select content into v_resp from extensions.http((
        'POST', rtrim(v_url,'/')||'/', array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_doc := v_resp::xml;
    exception when others then continue; end;

    select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_part
    from (
      select
        t.regid as itlid,
        (select vv.movil from public.vehiculosgps vv where vv.tracker_id::text = t.mid limit 1) as movil,
        (select vv.placa from public.vehiculosgps vv where vv.tracker_id::text = t.mid limit 1) as placa,
        p_ruta as ruta,
        ''::text as conductor,
        to_char(public._utc_ts(t.inittime) at time zone 'America/Bogota','HH24:MI') as hora,
        to_char(public._utc_ts(t.inittime) at time zone 'America/Bogota','YYYY-MM-DD') as fecha,
        case
          when t.running = 'Y' then round(extract(epoch from (now() - public._utc_ts(t.inittime)))/60)::int
          when public._utc_ts(t.endtime) is not null then round(extract(epoch from (public._utc_ts(t.endtime) - public._utc_ts(t.inittime)))/60)::int
          else null end as minutos,
        (t.running  = 'Y') as corriendo,
        (t.close    = 'Y') as cerrado,
        (t.canceled = 'Y') as cancelado
      from xmltable(
        xmlnamespaces('http://sonaravl.com/webservices/' as n),
        '//n:ItLog' passing v_doc
        columns
          regid    text path 'n:regId',
          mid      text path 'n:mId',
          running  text path 'n:running',
          close    text path 'n:close',
          canceled text path 'n:canceled',
          inittime text path 'n:inittime',
          endtime  text path 'n:endtime'
      ) t
      where public._utc_ts(t.inittime) is not null
    ) x;
    v_items := v_items || v_part;
  end loop;

  return jsonb_build_object('ok', true, 'ruta', p_ruta, 'fecha', p_fecha,
    'count', jsonb_array_length(v_items), 'items', v_items);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $fn$;
revoke all on function public.despachos_sonar_ruta(text, date) from public, anon;
grant execute on function public.despachos_sonar_ruta(text, date) to authenticated;

-- Limpieza de las funciones de sondeo usadas para diseñar esta consulta.
drop function if exists public._probe_ds_all(text, text);
drop function if exists public._probe_itlog_fields(bigint, text, text);
