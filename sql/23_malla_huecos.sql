-- ============================================================================
-- 23_malla_huecos.sql  (v164)
-- Mejora de malla_cumplimiento (22): RELLENA los huecos. Un punto queda en blanco
-- cuando el bus no registró esa geocerca (típico el punto 0 de despacho). Como la
-- hora programada (p_expectedtime) mantiene un OFFSET constante respecto a la hora
-- de despacho entre todos los viajes, se calcula ese offset por punto y se rellena
-- la celda faltante con la hora PROGRAMADA (marcada 'e'=esperado → gris en la UI).
-- Además se incluyen ingresos/salidas por celda (para pasajeros por geocerca, si
-- SONAR los reporta; hoy la flota 990 los manda en 0).
-- ============================================================================

create or replace function public.malla_cumplimiento(p_ruta text, p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_itid bigint; v_itids bigint[]; v_puntos jsonb; v_hdr_it bigint; v_out jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  if coalesce(p_ruta, '') = '' then return jsonb_build_object('ok', false, 'error', 'Falta la ruta.'); end if;
  if p_fecha is null then p_fecha := (now() at time zone 'America/Bogota')::date; end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  select array_agg(it_id) into v_itids from public.itinerario_rutas where ruta = p_ruta;
  if v_itids is null then return jsonb_build_object('ok', false, 'error', 'Esa ruta no tiene itinerario en SONAR.'); end if;

  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_ItinerariesHistory_v2';
  v_ini := to_char((p_fecha::timestamp     at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha+1)::timestamp at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec','12000',true);

  create temp table if not exists _mc(regid bigint, mid text, init_utc timestamptz, running text, canceled text,
    idx int, real_utc timestamptz, diff int, exp_utc timestamptz, pin int, pout int) on commit drop;
  truncate _mc;

  foreach v_itid in array v_itids loop
    v_body := '<?xml version="1.0" encoding="utf-8"?>'
      || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '">'
      || '<User>'||v_usr||'</User><Password>'||v_pwd||'</Password>'
      || '<Itinerary>'||v_itid||'</Itinerary>'
      || '<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
      || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';
    begin
      select content into v_resp from extensions.http((
        'POST', rtrim(v_url,'/')||'/', array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;
    exception when others then continue; end;

    insert into _mc
    select
      (xpath('/x:ItLog/x:regId/text()',    it, array[array['x', v_ns]]))[1]::text::bigint,
      (xpath('/x:ItLog/x:mId/text()',      it, array[array['x', v_ns]]))[1]::text,
      public._utc_ts((xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text),
      (xpath('/x:ItLog/x:running/text()',  it, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItLog/x:canceled/text()', it, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItPointLog/x:p_index/text()',     p, array[array['x', v_ns]]))[1]::text::int,
      public._utc_ts((xpath('/x:ItPointLog/x:p_realtime/text()',     p, array[array['x', v_ns]]))[1]::text),
      nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text,'')::int,
      public._utc_ts((xpath('/x:ItPointLog/x:p_expectedtime/text()', p, array[array['x', v_ns]]))[1]::text),
      (xpath('/x:ItPointLog/x:p_ingresos/text()', p, array[array['x', v_ns]]))[1]::text::int,
      (xpath('/x:ItPointLog/x:p_salidas/text()',  p, array[array['x', v_ns]]))[1]::text::int
    from unnest(xpath('//x:ItLog', v_xml, array[array['x', v_ns]])) as it,
         unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', it, array[array['x', v_ns]])) as p;
  end loop;

  -- Encabezado: puntos del itinerario con más puntos de la ruta.
  select (select it_id from public.itinerario_puntos where it_id = any(v_itids) group by it_id order by count(*) desc limit 1) into v_hdr_it;
  select jsonb_agg(jsonb_build_object('idx',point_index,'nombre',geofence_name) order by point_index) into v_puntos
    from public.itinerario_puntos where it_id = v_hdr_it;

  with off as (  -- offset (seg) desde el despacho hasta la hora programada, por punto
    select idx, mode() within group (order by extract(epoch from (exp_utc - init_utc))::int) as sec
    from _mc where exp_utc is not null and init_utc is not null group by idx
  ),
  trips as ( select distinct regid, mid, init_utc, running, canceled from _mc ),
  hdr as ( select (x->>'idx')::int idx from jsonb_array_elements(v_puntos) x ),
  cells as (
    select t.regid,
      jsonb_object_agg(h.idx::text,
        case when m.real_utc is not null then
          jsonb_build_object('h', to_char(m.real_utc at time zone 'America/Bogota','HH24:MI:SS'), 'd', m.diff, 'i', m.pin, 'o', m.pout)
        when o.sec is not null and t.init_utc is not null then
          jsonb_build_object('h', to_char((t.init_utc + (o.sec || ' seconds')::interval) at time zone 'America/Bogota','HH24:MI'), 'e', true)
        else null end
      ) filter (where m.real_utc is not null or (o.sec is not null and t.init_utc is not null)) as celdas
    from trips t cross join hdr h
    left join _mc m on m.regid = t.regid and m.idx = h.idx
    left join off o on o.idx = h.idx
    group by t.regid
  )
  select jsonb_agg(jsonb_build_object(
     'hora', to_char(t.init_utc at time zone 'America/Bogota','HH24:MI'),
     'sort', to_char(t.init_utc at time zone 'UTC','YYYY-MM-DD HH24:MI:SS'),
     'mid', t.mid,
     'movil', (select v.movil from public.vehiculosgps v where v.tracker_id::text = t.mid limit 1),
     'regid', t.regid, 'running', t.running, 'canceled', t.canceled,
     'celdas', coalesce(c.celdas, '{}'::jsonb)) order by t.init_utc)
   into v_out
  from trips t left join cells c on c.regid = t.regid;

  return jsonb_build_object('ok', true, 'ruta', p_ruta, 'fecha', p_fecha,
    'puntos', coalesce(v_puntos, '[]'::jsonb), 'viajes', coalesce(v_out, '[]'::jsonb));
end $fn$;

revoke all on function public.malla_cumplimiento(text, date) from public, anon;
grant execute on function public.malla_cumplimiento(text, date) to authenticated;

-- limpiar funciones de prueba
drop function if exists public._probe_malla(text, date);
drop function if exists public._probe_malla2(text, date);
drop function if exists public._probe_holes(text, date, text);
drop function if exists public._probe_pax(date);
