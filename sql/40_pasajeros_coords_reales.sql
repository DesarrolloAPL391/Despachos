-- 40: Coordenadas REALES de las paradas de pasajeros (no geocodificadas).
-- SONAR no da lat/lon en GET_PassengersCounter, PERO cada subida trae su hora GPS (gps_UTC).
-- Cruzando esa hora con la traza real del bus (GET_TrackerEventsHistory: lat/lon + GpsGMT),
-- se obtiene la coordenada exacta donde estaba el bus en ese instante. Verificado: la subida
-- cae en promedio a ~22 s del punto GPS más cercano (88% a <=60 s). Las 2 llamadas ~3.2 s.
--
-- pasajeros_movil ahora: 1) llama GET_PassengersCounter, 2) llama GET_TrackerEventsHistory
-- (best-effort), 3) por cada parada (p_station) promedia las coords GPS reales de sus eventos
-- (punto más cercano en el tiempo, <=180 s). Si no hay traza, deja lat/lon nulos y el cliente
-- geocodifica con TomTom (geo_cache). Marca 'real'=true cuando la coord viene del GPS.

create or replace function public.pasajeros_movil(p_movil text, p_fecha date)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_mid text; v_ini text; v_fin text; v_resp extensions.http_response; v_resp2 extensions.http_response; v_doc xml;
  v_status text; v_sub int; v_baj int; v_blq int; v_n int; v_ntrk int := 0;
  v_porhora jsonb; v_porpuerta jsonb; v_paradas jsonb;
begin
  if not (public.es_admin() or (public.es_afiliado() and trim(p_movil) = any(public.mis_moviles_afiliado()))) then
    raise exception 'No autorizado para consultar este móvil.'; end if;
  if nullif(trim(p_movil),'') is null then return jsonb_build_object('ok', false, 'error', 'Móvil vacío.'); end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Fecha vacía.'); end if;

  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'El móvil '||trim(p_movil)||' no tiene Id GPS en SONAR.'); end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter';

  -- Día Colombia [00:00, 23:59:59] en UTC (+5h): [fecha 05:00, fecha+1 04:59:59]. Mismo rango para la traza.
  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');

  -- 3.5 s por llamada: 2 llamadas caben en el statement_timeout de 8 s del rol authenticated.
  perform set_config('http.timeout_msec','3500',true);

  -- 1) Conteo de pasajeros
  select * into v_resp from extensions.http((
    'POST', rtrim(v_url,'/')||'/',
    array[extensions.http_header('SOAPAction', v_action)],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    ||'<GET_PassengersCounter xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
    ||'<mId>'||public._xmlesc(v_mid)||'</mId>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_PassengersCounter></soap:Body></soap:Envelope>'
  )::extensions.http_request);
  if v_resp.status <> 200 then return jsonb_build_object('ok', false, 'error', 'SONAR HTTP '||v_resp.status); end if;

  v_doc := xmlparse(document v_resp.content);
  v_status := (regexp_match(v_resp.content, '(?i)<status>([^<]*)</status>'))[1];

  -- Detalle por puerta + hora UTC + hora Colombia + dirección (p_station por regex del label).
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, coalesce(dblock,0) dblock, door,
         to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') ts_utc,
         (to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') - interval '5 hours') ts_co,
         nullif((regexp_match(station, '"label"\s*:\s*"([^"]*)"'))[1], '') estacion
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing v_doc
    columns
      door    int  path 'n:Door',
      din     int  path 'n:DoorIn',
      dout    int  path 'n:DoorOut',
      dblock  int  path 'n:DoorBlocking',
      gps     text path '../../n:gps_UTC',
      station text path '../../n:p_station'
  );

  select count(*), coalesce(sum(din),0), coalesce(sum(dout),0), coalesce(sum(dblock),0)
    into v_n, v_sub, v_baj, v_blq from _dd;

  select jsonb_agg(jsonb_build_object('hora', h, 'subidas', s, 'bajadas', b) order by h)
    into v_porhora
    from (select extract(hour from ts_co)::int h, sum(din) s, sum(dout) b
          from _dd where ts_co is not null group by 1) t;

  select jsonb_object_agg(door::text, s)
    into v_porpuerta
    from (select door, sum(din) s from _dd where door is not null group by door) t;

  -- 2) Traza GPS real del bus (best-effort: si falla, se geocodifica en el cliente).
  create temp table _trk (ts timestamp, lat float, lon float) on commit drop;
  begin
    select * into v_resp2 from extensions.http((
      'POST', v_url,
      array[extensions.http_header('SOAPAction', '"'||rtrim(v_ns,'/')||'/ServiceSoap/GET_TrackerEventsHistory"')],
      'text/xml; charset=utf-8',
      '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      ||'<GET_TrackerEventsHistory xmlns="'||v_ns||'">'
      ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
      ||'<mId>'||public._xmlesc(v_mid)||'</mId><eventID></eventID>'
      ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
      ||'</GET_TrackerEventsHistory></soap:Body></soap:Envelope>'
    )::extensions.http_request);
    if v_resp2.status = 200 then
      insert into _trk (ts, lat, lon)
      select g::timestamp, lat, lon
      from xmltable(
        xmlnamespaces('http://sonaravl.com/webservices/' as n),
        '//n:TrackerEvent' passing xmlparse(document v_resp2.content)
        columns lat float path 'n:Latitude', lon float path 'n:Longitude', g text path 'n:GpsGMT')
      where lat is not null and lon is not null and not (lat = 0 and lon = 0);
    end if;
  exception when others then
    null; -- sin traza: paradas quedan sin coord -> el cliente geocodifica (TomTom + geo_cache)
  end;
  select count(*) into v_ntrk from _trk;

  -- Paradas: agrupadas por dirección; coord = promedio de los puntos GPS reales de sus eventos
  -- (el más cercano en el tiempo, <=180 s). Respaldo: geo_cache. 'real' = vino del GPS.
  select jsonb_agg(x order by (x->>'subidas')::int desc)
    into v_paradas
    from (
      select jsonb_build_object(
        'parada', d.estacion, 'subidas', sum(d.din), 'bajadas', sum(d.dout),
        'lat', coalesce(round(avg(m.lat)::numeric, 6), g.lat),
        'lon', coalesce(round(avg(m.lon)::numeric, 6), g.lon),
        'real', (count(m.lat) > 0)
      ) x
      from _dd d
      left join lateral (
        select t.lat, t.lon
        from _trk t
        where abs(extract(epoch from (t.ts - d.ts_utc))) <= 180
        order by abs(extract(epoch from (t.ts - d.ts_utc)))
        limit 1
      ) m on true
      left join public.geo_cache g on g.direccion = d.estacion
      where d.estacion is not null
      group by d.estacion, g.lat, g.lon
      order by sum(d.din) desc
      limit 40
    ) q;

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'mid', v_mid, 'fecha', p_fecha,
    'status', coalesce(v_status,'OK'), 'registros', v_n, 'con_gps', v_ntrk,
    'subidas', v_sub, 'bajadas', v_baj, 'bloqueos', v_blq,
    'por_hora', coalesce(v_porhora, '[]'::jsonb),
    'por_puerta', coalesce(v_porpuerta, '{}'::jsonb),
    'paradas', coalesce(v_paradas, '[]'::jsonb)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

grant execute on function public.pasajeros_movil(text, date) to authenticated;
