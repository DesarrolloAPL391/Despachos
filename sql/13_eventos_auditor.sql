-- ============================================================================
-- 13_eventos_auditor.sql  (v130)
-- Eventos del bus en SONAR para la pantalla del AUDITOR.
--
-- Usa GET_TrackerEventsHistoryV2 (la V1 la usa `sonar_recorrido` para el mapa).
-- La V2 trae, en UNA sola llamada y en texto legible:
--   * pasos por geocerca:  "Ingreso a CONTROL EL PALO" / "Salida de DESPACHO NUTIBARA 130"
--   * "Exceso de velocidad" + RoadSpeed (límite de la vía) contra Speed (del bus)
--   * "Conduciendo con puerta abierta", encendido/apagado, odómetro
-- Verificado contra la flota 990: 131 eventos en 24 h en un móvil real.
--
-- SOLO AUDITORES Y ADMIN: es una herramienta de auditoría, no de despacho.
-- (Ojo: `sonar_recorrido` quedó ejecutable por anon; esta NO — ver sql/12.)
-- ============================================================================

create or replace function public.sonar_eventos_auditor(
  p_mid text,           -- Id del tracker en SONAR (ubicaciones.mid)
  p_desde text,         -- 'YYYY-MM-DD HH:MM' en hora de Colombia
  p_hasta text          -- 'YYYY-MM-DD HH:MM' en hora de Colombia
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sa text;
  v_body text; v_resp text; v_xml xml;
  v_ini text; v_fin text;
  v_status text;
  v_items jsonb;
begin
  -- Puerta: esta información es de auditoría (velocidad, puertas, geocercas).
  if not (public.es_auditor() or public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo los auditores pueden consultar los eventos del bus.');
  end if;
  if coalesce(p_mid, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Ese móvil no tiene Id GPS en SONAR.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  select regexp_replace(decrypted_secret, '/[^/]+$', '') into v_sa
    from vault.decrypted_secrets where name = 'SONAR_SOAPACTION';

  -- SONAR pide el rango en UTC; aquí se recibe en hora de Colombia.
  v_ini := to_char((p_desde::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char((p_hasta::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');

  v_body :=
    '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_TrackerEventsHistoryV2 xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
    || '<mId>' || p_mid || '</mId><eventID></eventID>'
    || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
    || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
    || '</GET_TrackerEventsHistoryV2></soap:Body></soap:Envelope>';

  perform set_config('http.timeout_msec', '55000', true); -- el V2 tarda más que el V1

  begin
    select content into v_resp from extensions.http((
      'POST', v_url,
      array[extensions.http_header('SOAPAction', v_sa || '/GET_TrackerEventsHistoryV2')],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'SONAR no respondió: ' || sqlerrm);
  end;

  v_xml := v_resp::xml;
  v_status := (xpath('//x:status/text()', v_xml, array[array['x', v_ns]]))[1]::text;
  if coalesce(v_status, '') <> 'OK' then
    return jsonb_build_object('ok', false, 'error',
      coalesce((xpath('//x:description/text()', v_xml, array[array['x', v_ns]]))[1]::text, 'SONAR respondió ' || coalesce(v_status, '?')));
  end if;

  -- Un objeto por evento. La hora se devuelve YA en hora de Colombia.
  select coalesce(jsonb_agg(e order by e->>'hora'), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
      'hora',      to_char(((xpath('/x:TrackerEventV2/x:GpsGMT/text()', n, array[array['x', v_ns]]))[1]::text)::timestamp
                            at time zone 'UTC' at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI:SS'),
      'evento',    (xpath('/x:TrackerEventV2/x:eventDescription/text()', n, array[array['x', v_ns]]))[1]::text,
      'direccion', (xpath('/x:TrackerEventV2/x:Address/text()', n, array[array['x', v_ns]]))[1]::text,
      'velocidad', nullif((xpath('/x:TrackerEventV2/x:Speed/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'limite',    nullif((xpath('/x:TrackerEventV2/x:RoadSpeed/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'lat',       nullif((xpath('/x:TrackerEventV2/x:Latitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'lon',       nullif((xpath('/x:TrackerEventV2/x:Longitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'odometro',  nullif((xpath('/x:TrackerEventV2/x:Odometer/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric
    ) as e
    from unnest(xpath('//x:TrackerEventV2', v_xml, array[array['x', v_ns]])) as n
  ) s;

  return jsonb_build_object('ok', true, 'items', v_items);
end $$;

-- Que no la pueda disparar cualquiera desde internet: solo usuarios con sesión,
-- y por dentro la función exige es_auditor()/es_admin().
revoke all on function public.sonar_eventos_auditor(text, text, text) from public, anon;
grant execute on function public.sonar_eventos_auditor(text, text, text) to authenticated;
