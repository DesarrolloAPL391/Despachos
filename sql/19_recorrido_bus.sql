-- ============================================================================
-- 19_recorrido_bus.sql  (v157)
-- "Recorrido en vivo" de un bus: por cuáles puntos de control (geocercas) del
-- itinerario ha pasado en su viaje actual, a qué hora, y si va a tiempo o atrasado.
--
-- Dos fuentes SOAP:
--  A) GET_FleetItineraries (flota 990) → DEFINICIÓN de cada itinerario con sus
--     puntos (nombre de la geocerca por índice). Es ESTÁTICO y pesado (~9 s, 233 KB)
--     → se cachea en itinerario_puntos, refrescado por cron 1 vez al día.
--  B) GET_ItinerariesHistory_v2 (mId + Itinerary) → HISTORIAL del móvil: sus viajes
--     del día con el ItPointsLog (índice de punto, hora real, hora esperada, minutos
--     de diferencia). Es RÁPIDO (~0.5 s por móvil) → se llama EN VIVO desde el cliente.
--
-- El cruce por índice de punto (log.p_index == def.point_index) le pone nombre a cada
-- parada. Tiempos de SONAR en UTC → se convierten a hora Colombia. Diferencia en minutos
-- (positivo = atrasado). Reutiliza public._utc_ts() de 18_rutas_en_vivo.sql.
-- ============================================================================

-- A) Caché de la definición de puntos por itinerario (estático).
create table if not exists public.itinerario_puntos (
  it_id        bigint  not null,
  point_index  int     not null,
  geofence_name text,
  primary key (it_id, point_index)
);
alter table public.itinerario_puntos enable row level security;  -- sin políticas: solo SECURITY DEFINER

create or replace function public.refrescar_itinerario_puntos_core()
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_n int := 0;
begin
  if not pg_try_advisory_xact_lock(724002) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  v_action := rtrim(v_ns, '/') || '/ServiceSoap/GET_FleetItineraries';
  perform set_config('http.timeout_msec', '50000', true);
  v_body := '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_FleetItineraries xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password><FleetId>990</FleetId>'
    || '</GET_FleetItineraries></soap:Body></soap:Envelope>';

  begin
    select content into v_resp from extensions.http((
      'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_action)],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
    v_xml := v_resp::xml;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'No se pudo consultar SONAR.');
  end;

  with defn as (
    select
      (xpath('/x:Itinerary/x:It_id/text()', it, array[array['x', v_ns]]))[1]::text::bigint as it_id,
      (xpath('/x:ItPoint/x:point_index/text()',   p, array[array['x', v_ns]]))[1]::text::int as point_index,
      (xpath('/x:ItPoint/x:geofence_name/text()', p, array[array['x', v_ns]]))[1]::text as geofence_name
    from unnest(xpath('//x:Itinerary', v_xml, array[array['x', v_ns]])) as it,
         unnest(xpath('/x:Itinerary/x:ItPoints/x:ItPoint', it, array[array['x', v_ns]])) as p
  )
  insert into public.itinerario_puntos (it_id, point_index, geofence_name)
  select it_id, point_index, geofence_name from defn where it_id is not null and point_index is not null
  on conflict (it_id, point_index) do update set geofence_name = excluded.geofence_name;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'puntos', (select count(*) from public.itinerario_puntos));
end $fn$;

revoke all on function public.refrescar_itinerario_puntos_core() from public, anon, authenticated;

-- Cron: 1 vez al día (04:20 hora servidor) refresca la definición de puntos.
select cron.schedule('refrescar-itinerario-puntos', '20 4 * * *',
                     'select public.refrescar_itinerario_puntos_core();');

-- B) LECTOR en vivo: recorrido del viaje actual de un móvil.
create or replace function public.recorrido_bus(p_mid text, p_itid bigint)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_node xml; v_regid text; v_running text; v_init text; v_end text;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  if coalesce(trim(p_mid), '') = '' or p_itid is null then
    return jsonb_build_object('ok', false, 'error', 'Faltan datos del móvil.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  v_action := rtrim(v_ns, '/') || '/ServiceSoap/GET_ItinerariesHistory_v2';
  -- ventana amplia en UTC que siempre cubre el viaje en curso (SONAR interpreta el rango en UTC)
  v_ini := to_char((now() - interval '18 hours') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char((now() + interval '2 hours')  at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec', '30000', true);

  v_body := '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
    || '<mId>' || p_mid || '</mId><Itinerary>' || p_itid || '</Itinerary>'
    || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
    || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
    || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';

  begin
    select content into v_resp from extensions.http((
      'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_action)],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
    v_xml := v_resp::xml;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'No se pudo consultar SONAR.');
  end;

  -- Elige el viaje objetivo: el que esté corriendo; si ninguno, el de inittime más reciente.
  select node, regid, running, init, fin into v_node, v_regid, v_running, v_init, v_end
  from (
    select it as node,
      (xpath('/x:ItLog/x:regId/text()',    it, array[array['x', v_ns]]))[1]::text as regid,
      (xpath('/x:ItLog/x:running/text()',  it, array[array['x', v_ns]]))[1]::text as running,
      (xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text as init,
      (xpath('/x:ItLog/x:endtime/text()',  it, array[array['x', v_ns]]))[1]::text as fin
    from unnest(xpath('//x:ItLog', v_xml, array[array['x', v_ns]])) as it
  ) t
  order by (running = 'Y') desc nulls last, init desc
  limit 1;

  if v_node is null then
    return jsonb_build_object('ok', true, 'encontrado', false);
  end if;

  return (
    with logged as (
      select
        (xpath('/x:ItPointLog/x:p_index/text()',        p, array[array['x', v_ns]]))[1]::text::int as idx,
        public._utc_ts((xpath('/x:ItPointLog/x:p_realtime/text()',     p, array[array['x', v_ns]]))[1]::text) as real_ts,
        public._utc_ts((xpath('/x:ItPointLog/x:p_expectedtime/text()', p, array[array['x', v_ns]]))[1]::text) as esp_ts,
        nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text, '')::int as diff
      from unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', v_node, array[array['x', v_ns]])) as p
    ),
    def as (select point_index, geofence_name from public.itinerario_puntos where it_id = p_itid),
    merged as (
      select
        coalesce(d.point_index, l.idx) as idx,
        coalesce(d.geofence_name, 'Punto ' || coalesce(d.point_index, l.idx)) as nombre,
        l.real_ts, l.esp_ts, l.diff
      from def d
      full outer join logged l on l.idx = d.point_index
    )
    select jsonb_build_object(
      'ok', true, 'encontrado', true,
      'regid', v_regid,
      'en_curso', (v_running = 'Y'),
      'inicio',  to_char(public._utc_ts(v_init) at time zone 'America/Bogota', 'HH24:MI'),
      'fin',     to_char(public._utc_ts(v_end)  at time zone 'America/Bogota', 'HH24:MI'),
      'total',    (select count(*) from merged),
      'pasados',  (select count(*) from merged where real_ts is not null),
      'atraso',   (select diff from merged where real_ts is not null order by idx desc limit 1),
      'puntos', coalesce((
        select jsonb_agg(jsonb_build_object(
          'idx', idx, 'nombre', nombre,
          'real',     to_char(real_ts at time zone 'America/Bogota', 'HH24:MI'),
          'esperada', to_char(esp_ts  at time zone 'America/Bogota', 'HH24:MI'),
          'diff', diff
        ) order by idx) from merged), '[]'::jsonb)
    )
  );
end $fn$;

revoke all on function public.recorrido_bus(text, bigint) from public, anon;
grant execute on function public.recorrido_bus(text, bigint) to authenticated;

-- Semilla: llena la definición de puntos ya mismo (no esperar al cron diario).
select public.refrescar_itinerario_puntos_core();

-- limpia funciones de prueba de la sesión de desarrollo
drop function if exists public._probe_itpoints(text, text);
drop function if exists public._probe_puntos_def();
