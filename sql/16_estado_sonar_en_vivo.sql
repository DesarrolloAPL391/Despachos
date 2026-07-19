-- ============================================================================
-- 16_estado_sonar_en_vivo.sql  (v145)
-- Cruce EN VIVO de un despacho de la app con su viaje REAL en SONAR, por regId.
--
-- El regId que la app guarda al despachar (columna sonar_regid de las tablas de
-- puesto / despachos) ES el itlId de SONAR. Este RPC llama GET_DispatchedVehicles
-- (endpoint sapps.asmx) para ese móvil y día, GUARDA todos los viajes que devuelve
-- en public.despachos_sonar (upsert) y retorna el que coincide con el regId, con su
-- estado calculado (Completo / Incompleto / Cancelado / En progreso).
--
-- Reutiliza el mismo sobre SOAP y la misma regla de estado de 15_despachos_sonar.sql
-- (el estado es una columna generada en despachos_sonar: una sola verdad).
--
-- NO toca despachos_sonar_sync a propósito: el sync por lotes sigue siendo la fuente
-- COMPLETA del día. Este cruce es puntual y puede correr antes de que el viaje cierre
-- (mostraría "En progreso"); si marcáramos el móvil como sincronizado, el lote nocturno
-- se saltaría los viajes que ese móvil despache después.
-- ============================================================================

create or replace function public.estado_sonar_en_vivo(p_mid text, p_fecha date, p_regid bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sapps text; v_action text;
  v_body text; v_resp text; v_xml xml; v_estado text;
  v_ini text; v_fin text;
begin
  -- Cualquier usuario autenticado puede consultar el estado de un despacho suyo
  -- (el botón solo aparece en las filas que ya ve/opera). Devuelve solo el viaje
  -- del regId pedido; no expone la tabla completa (esa sigue con su RLS).
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'No autenticado.');
  end if;
  if coalesce(trim(p_mid), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'El móvil no tiene Id GPS (mId) en SONAR.');
  end if;
  if p_regid is null then
    return jsonb_build_object('ok', false, 'error', 'Ese despacho no tiene regId.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  -- GET_DispatchedVehicles vive en el OTRO endpoint (sapps.asmx), no en el del vault.
  v_sapps  := rtrim(v_url, '/') || '/sapps.asmx';
  v_action := rtrim(v_ns, '/') || '/GET_DispatchedVehicles';
  v_ini := to_char(p_fecha, 'YYYY-MM-DD') || ' 00:00:00';        -- hora de Colombia
  v_fin := to_char(p_fecha + 1, 'YYYY-MM-DD') || ' 00:00:00';

  perform set_config('http.timeout_msec', '50000', true);

  v_body :=
    '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_DispatchedVehicles xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
    || '<fleetId>990</fleetId><mId>' || p_mid || '</mId>'
    || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
    || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
    || '</GET_DispatchedVehicles></soap:Body></soap:Envelope>';

  begin
    select content into v_resp from extensions.http((
      'POST', v_sapps, array[extensions.http_header('SOAPAction', v_action)],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
    v_xml := v_resp::xml;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'No se pudo consultar SONAR.');
  end;

  -- Guarda TODOS los viajes del móvil ese día (mismo upsert que el sync por lotes).
  begin
    insert into public.despachos_sonar as d
      (itl_id, fecha, mid, movil, placa, ruta, conductor, hora_inicio, elapsed_seg,
       comentario, lclose, lrunning, lcanceled, lcanceledbyuser, sincronizado_en)
    select
      ((xpath('/x:ItDispatches/x:itlId/text()', n, array[array['x', v_ns]]))[1]::text)::bigint,
      p_fecha,
      (xpath('/x:ItDispatches/x:mId/text()',    n, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItDispatches/x:mDesc/text()',  n, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItDispatches/x:mPlaca/text()', n, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItDispatches/x:itDesc/text()', n, array[array['x', v_ns]]))[1]::text,
      (xpath('/x:ItDispatches/x:drName/text()', n, array[array['x', v_ns]]))[1]::text,
      nullif((xpath('/x:ItDispatches/x:initTime/text()', n, array[array['x', v_ns]]))[1]::text, '')::time,
      nullif((xpath('/x:ItDispatches/x:elapsed/text()',  n, array[array['x', v_ns]]))[1]::text, '')::int,
      (xpath('/x:ItDispatches/x:comments/text()', n, array[array['x', v_ns]]))[1]::text,
      nullif((xpath('/x:ItDispatches/x:lclose/text()',          n, array[array['x', v_ns]]))[1]::text, '')::boolean,
      nullif((xpath('/x:ItDispatches/x:lrunning/text()',        n, array[array['x', v_ns]]))[1]::text, '')::boolean,
      nullif((xpath('/x:ItDispatches/x:lcanceled/text()',       n, array[array['x', v_ns]]))[1]::text, '')::boolean,
      nullif((xpath('/x:ItDispatches/x:lcanceledbyuser/text()', n, array[array['x', v_ns]]))[1]::text, '')::boolean,
      now()
    from unnest(xpath('//x:ItDispatches', v_xml, array[array['x', v_ns]])) as n
    on conflict (itl_id) do update set
      lclose = excluded.lclose, lrunning = excluded.lrunning,
      lcanceled = excluded.lcanceled, lcanceledbyuser = excluded.lcanceledbyuser,
      elapsed_seg = excluded.elapsed_seg, sincronizado_en = now();
  exception when others then
    null;  -- si el parseo falla, igual intentamos leer lo que ya hubiera del regId
  end;

  -- ¿Quedó el viaje buscado?
  select estado into v_estado from public.despachos_sonar where itl_id = p_regid;
  if v_estado is null then
    return jsonb_build_object('ok', true, 'encontrado', false, 'regid', p_regid);
  end if;

  return (
    select jsonb_build_object(
      'ok', true, 'encontrado', true,
      'regid', d.itl_id, 'estado', d.estado, 'movil', d.movil, 'placa', d.placa,
      'ruta', d.ruta, 'conductor', d.conductor,
      'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
      'elapsed_seg', d.elapsed_seg, 'comentario', d.comentario)
    from public.despachos_sonar d where d.itl_id = p_regid
  );
end $$;

revoke all on function public.estado_sonar_en_vivo(text, date, bigint) from public, anon;
grant execute on function public.estado_sonar_en_vivo(text, date, bigint) to authenticated;
