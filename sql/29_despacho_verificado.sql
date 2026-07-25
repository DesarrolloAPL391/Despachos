-- ============================================================================
-- 29_despacho_verificado.sql  (v175)  Anti-doble-despacho: verificar contra SONAR
--
-- Problema real (incidente 21/07, móvil 8186 ruta 190): SONAR respondió LENTO
-- (>5 s = timeout por defecto de extensions.http). La app creyó que falló, marcó
-- PENDIENTE SONAR y envió el correo... pero SONAR SÍ había creado el viaje
-- (regId 80580957). Al reenviarlo con ▶ se creó un DUPLICADO (80581020) y hubo que
-- cancelar el fantasma a mano. Un timeout NO significa "SONAR no lo recibió".
--
-- Solución (dos piezas; la lógica del cliente vive en app.js):
--   1) despachar_sonar: subir el timeout HTTP a 6.5 s (bajo el statement_timeout=8 s
--      de authenticated) para que SONAR alcance a responder más seguido en línea.
--   2) verificar_viaje_sonar(): pregunta a SONAR (GET_ItinerariesHistory_v2) si el
--      viaje del móvil YA quedó creado en el itinerario. Devuelve su regId real.
--      El cliente la usa: (a) tras un fallo/timeout, antes de marcar PENDIENTE +
--      correo -> si el viaje existe, ADOPTA ese regId (sin doble, sin correo); y
--      (b) antes de reenviar un PENDIENTE -> si ya existe, no re-despacha.
-- Solo si SONAR de verdad NO tiene el viaje, ahí sí queda PENDIENTE y se avisa.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) despachar_sonar con timeout HTTP explícito (6.5 s). Igual que antes salvo
--    la línea de set_config('http.timeout_msec', ...).
-- ---------------------------------------------------------------------------
create or replace function public.despachar_sonar(
  p_mid text, p_itinerary text, p_drvid text, p_utc text default ''::text, p_comments text default ''::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_envelope text; v_resp extensions.http_response; v_regid text;
begin
  select decrypted_secret into v_user   from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass   from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url    from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns     from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  select decrypted_secret into v_action from vault.decrypted_secrets where name='SONAR_SOAPACTION';
  if v_url is null then return jsonb_build_object('ok',false,'error','Falta configurar SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := coalesce(v_action, rtrim(v_ns,'/') || '/ServiceSoap/SET_ItAssign_v2');

  v_envelope :=
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><SET_ItAssign_v2 xmlns="' || v_ns || '">' ||
    '<User>'         || public._xmlesc(v_user)      || '</User>' ||
    '<Password>'     || public._xmlesc(v_pass)      || '</Password>' ||
    '<mId>'          || public._xmlesc(p_mid)       || '</mId>' ||
    '<Itinerary>'    || public._xmlesc(p_itinerary) || '</Itinerary>' ||
    '<DrvId>'        || public._xmlesc(p_drvid)     || '</DrvId>' ||
    '<UTC_datetime>' || public._xmlesc(p_utc)       || '</UTC_datetime>' ||
    '<comments>'     || public._xmlesc(p_comments)  || '</comments>' ||
    '</SET_ItAssign_v2></soap:Body></soap:Envelope>';

  -- 6.5 s: le damos más aire a SONAR (antes 5 s por defecto) pero por debajo del
  -- statement_timeout de 8 s, para que el 'exception' alcance a devolver el error.
  perform set_config('http.timeout_msec','6500',true);

  select * into v_resp from extensions.http((
    'POST', v_url,
    array[ extensions.http_header('SOAPAction', '"' || v_action || '"') ],
    'text/xml; charset=utf-8',
    v_envelope
  )::extensions.http_request);

  -- Captura del regId que devuelve SONAR (probamos varios nombres de etiqueta)
  v_regid := coalesce(
    (regexp_match(v_resp.content, '(?i)<(?:\w+:)?reg[ _]?id>([^<]+)</'))[1],
    (regexp_match(v_resp.content, '(?i)reg[ _]?id\s*[:=>"]+\s*([0-9]+)'))[1]
  );

  return jsonb_build_object('ok', (v_resp.status between 200 and 299), 'status', v_resp.status, 'regid', v_regid, 'response', v_resp.content);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2) verificar_viaje_sonar: ¿el móvil ya tiene un viaje VIVO en este itinerario?
--    Usa GET_ItinerariesHistory_v2 (mismo patrón que despachos_sonar_ruta / sql 26),
--    filtra por mId (y por conductor si se pasa), descarta cancelados, exige que el
--    viaje sea reciente (<=90 min) o esté en curso, y devuelve el MÁS reciente.
--    Timeout propio de 7 s: presupuesto fresco, aparte del intento de despacho.
-- ---------------------------------------------------------------------------
create or replace function public.verificar_viaje_sonar(
  p_mid text, p_itinerary text, p_drvid text default '', p_fecha date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, vault
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_doc xml; v_ini text; v_fin text;
  v_row record;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  if coalesce(p_mid,'') = '' or coalesce(p_itinerary,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta mId o itinerario.');
  end if;
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
  perform set_config('http.timeout_msec','7000',true);

  v_body := '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_ItinerariesHistory_v2 xmlns="'||v_ns||'"><User>'||public._xmlesc(v_usr)||'</User><Password>'||public._xmlesc(v_pwd)||'</Password>'
    || '<Itinerary>'||public._xmlesc(p_itinerary)||'</Itinerary><UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';

  begin
    select content into v_resp from extensions.http((
      'POST', rtrim(v_url,'/')||'/', array[extensions.http_header('SOAPAction', v_action)],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
    v_doc := v_resp::xml;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'No se pudo consultar SONAR: '||SQLERRM);
  end;

  -- El viaje "nuestro": mismo móvil (mId) en el itinerario, NO cancelado, reciente
  -- (<=90 min) o en curso; el MÁS reciente. Si nos pasan el conductor, debe coincidir
  -- para no adoptar un viaje ajeno del mismo móvil. Un cancelado se ignora a propósito:
  -- ese viaje está muerto, así que re-despachar NO es un duplicado.
  select t.regid, t.running, t.close, t.canceled,
         to_char(public._utc_ts(t.inittime) at time zone 'America/Bogota','HH24:MI') as hora
    into v_row
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:ItLog' passing v_doc
    columns
      regid    text path 'n:regId',
      mid      text path 'n:mId',
      driver   text path 'n:driver',
      running  text path 'n:running',
      close    text path 'n:close',
      canceled text path 'n:canceled',
      inittime text path 'n:inittime'
  ) t
  where t.mid = p_mid
    and coalesce(t.regid,'') <> '' and t.regid <> '0'
    and coalesce(t.canceled,'N') <> 'Y'
    and (coalesce(p_drvid,'') = '' or t.driver = p_drvid)
    and public._utc_ts(t.inittime) is not null
    and (t.running = 'Y' or public._utc_ts(t.inittime) >= now() - interval '90 minutes')
  order by public._utc_ts(t.inittime) desc
  limit 1;

  if v_row.regid is null then
    return jsonb_build_object('ok', true, 'encontrado', false);
  end if;
  return jsonb_build_object('ok', true, 'encontrado', true,
    'regid', v_row.regid, 'hora', v_row.hora,
    'corriendo', (v_row.running='Y'), 'cerrado', (v_row.close='Y'), 'cancelado', (v_row.canceled='Y'));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $fn$;
revoke all on function public.verificar_viaje_sonar(text, text, text, date) from public, anon;
grant execute on function public.verificar_viaje_sonar(text, text, text, date) to authenticated;
